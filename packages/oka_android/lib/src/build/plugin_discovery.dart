import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'host_codegen.dart';

/// A discovered Flutter plugin with optional Android metadata.
class DiscoveredPlugin {
  final String name;
  final String path;
  final String? androidPackage;
  final String? pluginClass;
  final bool hasAndroid;

  /// True when Android integration looks too complex for oka (Gradle-only).
  final bool unsupportedNative;
  final String? unsupportedReason;

  const DiscoveredPlugin({
    required this.name,
    required this.path,
    this.androidPackage,
    this.pluginClass,
    this.hasAndroid = false,
    this.unsupportedNative = false,
    this.unsupportedReason,
  });

  /// Fully-qualified Java class if known.
  String? get qualifiedClass {
    if (androidPackage == null || pluginClass == null) return null;
    return '$androidPackage.$pluginClass';
  }
}

/// Result of scanning a Flutter project for plugins.
class PluginDiscoveryResult {
  /// Returns a copy without the named plugins (test-only plugins etc.).
  PluginDiscoveryResult excluding(List<String> names) {
    if (names.isEmpty) return this;
    bool keep(dynamic p) => !names.contains((p as dynamic).name as String);
    return PluginDiscoveryResult(
      plugins: plugins.where(keep).toList(),
      unsupported: unsupported.where(keep).toList(),
    );
  }

  final List<DiscoveredPlugin> plugins;
  final List<DiscoveredPlugin> unsupported;

  const PluginDiscoveryResult({
    required this.plugins,
    required this.unsupported,
  });

  List<DiscoveredPlugin> get androidPlugins =>
      plugins.where((p) => p.hasAndroid).toList();

  bool get hasUnsupported => unsupported.isNotEmpty;
}

/// Plugin names that previously required soft-mode skip.
///
/// With NDK/CMake packaging, `jni` is packable; keep empty by default so
/// complete builds register all plugins. Soft-mode opt-out may still list names.
const kDefaultSoftSkipPluginNames = <String>{};

/// True when a plugin should be treated as unsupported native for oka.
///
/// Default is false for jni (packaged via CMake/NDK). Override lists can mark
/// plugins for soft-skip when explicitly requested.
bool isKnownUnsupportedPluginName(
  String name, {
  Set<String> softSkipNames = const {},
}) {
  final n = name.toLowerCase();
  if (softSkipNames.contains(n)) return true;
  if (kDefaultSoftSkipPluginNames.contains(n)) return true;
  return false;
}

/// Soft-mode gate: either hard-fail or return skip warnings.
class PluginSupportDecision {
  final bool allowBuild;
  final bool softMode;
  final List<DiscoveredPlugin> skipped;
  final List<String> warnings;

  const PluginSupportDecision({
    required this.allowBuild,
    required this.softMode,
    required this.skipped,
    required this.warnings,
  });
}

/// Decide whether build may proceed given unsupported plugins.
///
/// - [strict] true (default): hard-fail when unsupported present
/// - [strict] false (soft): allow build, skip unsupported from registrant
PluginSupportDecision decidePluginSupport(
  PluginDiscoveryResult result, {
  bool strict = true,
}) {
  if (!result.hasUnsupported) {
    return const PluginSupportDecision(
      allowBuild: true,
      softMode: false,
      skipped: [],
      warnings: [],
    );
  }
  final skipped = List<DiscoveredPlugin>.from(result.unsupported);
  if (strict) {
    return PluginSupportDecision(
      allowBuild: false,
      softMode: false,
      skipped: skipped,
      warnings: skipped
          .map((p) =>
              '${p.name}: ${p.unsupportedReason ?? "unsupported native"}')
          .toList(),
    );
  }
  return PluginSupportDecision(
    allowBuild: true,
    softMode: true,
    skipped: skipped,
    warnings: skipped
        .map((p) =>
            'soft-plugins: skipping ${p.name} (${p.unsupportedReason ?? "unsupported"})')
        .toList(),
  );
}

/// Parses Flutter's `.flutter-plugins-dependencies` JSON (Flutter 2+).
PluginDiscoveryResult parseFlutterPluginsDependenciesJson(
  String jsonContent, {
  String projectRoot = '',
}) {
  final map = jsonDecode(jsonContent) as Map<String, dynamic>;
  final plugins = <DiscoveredPlugin>[];
  final unsupported = <DiscoveredPlugin>[];

  // Format: { "plugins": { "android": [ { "name", "path", ... } ], ... } }
  final pluginsSection = map['plugins'];
  if (pluginsSection is Map) {
    final androidList = pluginsSection['android'];
    if (androidList is List) {
      for (final entry in androidList) {
        if (entry is! Map) continue;
        final name = entry['name']?.toString() ?? '';
        final path = entry['path']?.toString() ?? '';
        final nativeBuild = entry['native_build'] == true;
        final sharedDarwin = entry['shared_darwin_source'] == true;
        var unsupportedNative = false;
        String? reason;
        // Heuristic: explicit native_build flags complex NDK plugins.
        if (nativeBuild && entry['dependencies'] is List) {
          final deps = entry['dependencies'] as List;
          if (deps.length > 15) {
            unsupportedNative = true;
            reason = 'Plugin declares a large native dependency graph';
          }
        }
        final plugin = DiscoveredPlugin(
          name: name,
          path: path,
          hasAndroid: true,
          unsupportedNative: unsupportedNative,
          unsupportedReason: reason,
        );
        plugins.add(plugin);
        if (unsupportedNative) unsupported.add(plugin);
        // silence unused
        if (sharedDarwin) {}
      }
    }

    // Also collect ios-only etc. as non-android plugins without android flag
    for (final platform in ['ios', 'macos', 'windows', 'linux', 'web']) {
      final list = pluginsSection[platform];
      if (list is! List) continue;
      for (final entry in list) {
        if (entry is! Map) continue;
        final name = entry['name']?.toString() ?? '';
        if (plugins.any((p) => p.name == name)) continue;
        plugins.add(
          DiscoveredPlugin(
            name: name,
            path: entry['path']?.toString() ?? '',
            hasAndroid: false,
          ),
        );
      }
    }
  }

  return PluginDiscoveryResult(plugins: plugins, unsupported: unsupported);
}

/// Parses legacy `.flutter-plugins` (name=path per line).
List<DiscoveredPlugin> parseFlutterPluginsFile(String content) {
  final result = <DiscoveredPlugin>[];
  for (final line in content.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final idx = trimmed.indexOf('=');
    if (idx <= 0) continue;
    final name = trimmed.substring(0, idx).trim();
    final path = trimmed.substring(idx + 1).trim();
    result.add(DiscoveredPlugin(name: name, path: path, hasAndroid: true));
  }
  return result;
}

/// Reads plugin Android class from plugin's pubspec.yaml `flutter.plugin` section.
Future<DiscoveredPlugin> enrichPluginFromPubspec(DiscoveredPlugin plugin) async {
  final pubspecPath = p.join(plugin.path, 'pubspec.yaml');
  final file = File(pubspecPath);
  if (!await file.exists()) {
    return plugin;
  }
  try {
    final doc = loadYaml(await file.readAsString());
    if (doc is! Map) return plugin;
    final flutter = doc['flutter'];
    if (flutter is! Map) return plugin;
    final pluginSection = flutter['plugin'];
    if (pluginSection is! Map) return plugin;

    // Platforms map (modern)
    final platforms = pluginSection['platforms'];
    if (platforms is Map && platforms['android'] is Map) {
      final android = platforms['android'] as Map;
      final packageName = android['package']?.toString();
      final pluginClass = android['pluginClass']?.toString();
      final hasAndroid = true;

      // Detect unsupported: dart-only plugins are fine; check for fancy gradle
      var unsupported = plugin.unsupportedNative;
      String? reason = plugin.unsupportedReason;
      final androidDir = Directory(p.join(plugin.path, 'android'));
      if (await androidDir.exists()) {
        final buildGradle = File(p.join(androidDir.path, 'build.gradle'));
        final buildGradleKts =
            File(p.join(androidDir.path, 'build.gradle.kts'));
        final gradleFile = await buildGradle.exists()
            ? buildGradle
            : (await buildGradleKts.exists() ? buildGradleKts : null);
        if (gradleFile != null) {
          final gradle = await gradleFile.readAsString();
          if (_looksUnsupportedGradle(gradle)) {
            unsupported = true;
            reason = 'Plugin Android Gradle uses features oka does not support '
                '(NDK externalNativeBuild, composite builds, or custom AGP plugins)';
          }
        }
      }

      return DiscoveredPlugin(
        name: plugin.name,
        path: plugin.path,
        androidPackage: packageName,
        pluginClass: pluginClass,
        hasAndroid: hasAndroid,
        unsupportedNative: unsupported,
        unsupportedReason: reason,
      );
    }

    // Legacy androidPackage / pluginClass at plugin root
    final packageName = pluginSection['androidPackage']?.toString();
    final pluginClass = pluginSection['pluginClass']?.toString();
    return DiscoveredPlugin(
      name: plugin.name,
      path: plugin.path,
      androidPackage: packageName,
      pluginClass: pluginClass,
      hasAndroid: packageName != null || pluginClass != null,
      unsupportedNative: plugin.unsupportedNative,
      unsupportedReason: plugin.unsupportedReason,
    );
  } catch (_) {
    return plugin;
  }
}

bool _looksUnsupportedGradle(String gradle) {
  // CMake/NDK is handled by PluginPackager — not auto-unsupported.
  // Only AGP plugins we cannot replicate without Gradle are unsupported.
  if (gradle.contains('com.google.gms.google-services') ||
      gradle.contains('com.google.firebase.crashlytics') ||
      gradle.contains('includeBuild(')) {
    return true;
  }
  return false;
}

/// Discover plugins for a Flutter project directory.
class PluginDiscovery {
  final bool verbose;

  PluginDiscovery({this.verbose = false});

  Future<PluginDiscoveryResult> discover(String projectPath) async {
    final depsFile =
        File(p.join(projectPath, '.flutter-plugins-dependencies'));
    final legacyFile = File(p.join(projectPath, '.flutter-plugins'));

    PluginDiscoveryResult base;
    if (await depsFile.exists()) {
      base = parseFlutterPluginsDependenciesJson(
        await depsFile.readAsString(),
        projectRoot: projectPath,
      );
    } else if (await legacyFile.exists()) {
      final list = parseFlutterPluginsFile(await legacyFile.readAsString());
      base = PluginDiscoveryResult(plugins: list, unsupported: const []);
    } else {
      // Empty — may need flutter pub get first
      if (verbose) {
        print(
          '   No .flutter-plugins-dependencies found; assuming zero plugins',
        );
      }
      base = const PluginDiscoveryResult(plugins: [], unsupported: []);
    }

    final enriched = <DiscoveredPlugin>[];
    final unsupported = <DiscoveredPlugin>[];
    for (final plugin in base.plugins) {
      var e = await enrichPluginFromPubspec(plugin);
      // Only mark unsupported for explicitly configured soft-skip names.
      // jni is packaged via NDK/CMake in PluginPackager — not auto-unsupported.
      if (!e.unsupportedNative && isKnownUnsupportedPluginName(e.name)) {
        e = DiscoveredPlugin(
          name: e.name,
          path: e.path,
          androidPackage: e.androidPackage,
          pluginClass: e.pluginClass,
          hasAndroid: e.hasAndroid,
          unsupportedNative: true,
          unsupportedReason:
              'plugin "${e.name}" is marked unsupported for no-Gradle packaging',
        );
      }
      enriched.add(e);
      if (e.unsupportedNative) unsupported.add(e);
    }

    return PluginDiscoveryResult(plugins: enriched, unsupported: unsupported);
  }

  /// Build registrant registrations from discovery (skips unsupported).
  List<PluginRegistration> toRegistrations(PluginDiscoveryResult result) {
    final regs = <PluginRegistration>[];
    for (final plugin in result.androidPlugins) {
      if (plugin.unsupportedNative) continue;
      final q = plugin.qualifiedClass;
      if (q == null) continue;
      regs.add(PluginRegistration(className: q, name: plugin.name));
    }
    return regs;
  }

  /// Throws if unsupported plugins are present and [strict] is true.
  void ensureSupported(PluginDiscoveryResult result, {bool strict = true}) {
    final decision = decidePluginSupport(result, strict: strict);
    if (decision.allowBuild) return;
    final names = decision.warnings.join('\n  - ');
    throw Exception(
      'Unsupported Flutter plugins for no-Gradle build:\n  - $names\n'
      'Use --soft-plugins to skip them, or remove them / add AAR packaging support.',
    );
  }

  /// Soft-mode helper: returns warnings to print; never throws.
  List<String> softSkipWarnings(PluginDiscoveryResult result) {
    return decidePluginSupport(result, strict: false).warnings;
  }
}
