/// Consumer ProGuard rules declared by a **source** Flutter plugin.
///
/// ADR-0051 propagates the consumer rules an AAR dependency ships
/// (`proguard.txt`). A Flutter plugin that is built from source declares the
/// same contract in its Gradle script instead:
///
/// ```gradle
/// android {
///     defaultConfig {
///         consumerProguardFiles 'proguard-rules.pro'
///     }
/// }
/// ```
///
/// AGP turns that declaration into the consumer rules of the library's AAR;
/// in oka's no-Gradle path the plugin is compiled from source, so the
/// declaration has to be read and fed to the shrinker directly — otherwise
/// the plugin's keep rules (e.g. the `@JavascriptInterface` members of
/// `flutter_inappwebview_android`) never reach R8.
///
/// Only `consumerProguardFiles` is propagated. A library's own
/// `proguardFiles` (e.g. `getDefaultProguardFile('proguard-android.txt')`)
/// describe how the *library* is minified, not how its consumers are
/// protected — AGP does not export them either.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Gradle script names a plugin module may use, in a deterministic order.
const pluginGradleScriptNames = <String>[
  'build.gradle',
  'build.gradle.kts',
];

/// A consumer-rule file declared by a plugin.
class PluginConsumerRuleFile {
  const PluginConsumerRuleFile({
    required this.pluginName,
    required this.path,
  });

  /// Flutter plugin name that declared the file (attribution).
  final String pluginName;

  /// Absolute path of the declared rule file.
  final String path;

  @override
  String toString() => '$pluginName → $path';
}

/// What a plugin's Gradle script declares about consumer rules.
class PluginConsumerRuleDiscovery {
  const PluginConsumerRuleDiscovery({
    required this.pluginName,
    this.files = const [],
    this.missing = const [],
  });

  final String pluginName;

  /// Declared rule files that exist on disk (absolute paths, sorted).
  final List<String> files;

  /// Declared rule files that do not exist (absolute paths, sorted).
  final List<String> missing;

  bool get isEmpty => files.isEmpty && missing.isEmpty;
}

/// Parses the `consumerProguardFiles` declarations of a Gradle script body.
///
/// Supports the shapes Flutter plugins use in practice:
/// `consumerProguardFiles 'a.pro'`, `consumerProguardFiles("a.pro")`,
/// `consumerProguardFile("a.pro")` and `file('a.pro')` wrappers. The
/// returned names are the *declared* strings, in declaration order; the
/// caller resolves them against the module directory.
List<String> parseConsumerProguardFiles(String gradleText) {
  final out = <String>[];
  final declaration = RegExp(r'consumerProguardFiles?\s*(\(|\s)');
  final quoted = RegExp('''['"]([^'"]+)['"]''');
  for (final match in declaration.allMatches(gradleText)) {
    final rest = gradleText.substring(match.end);
    final args = match.group(1) == '('
        ? _balancedArguments(rest)
        : _lineArguments(rest);
    for (final quotedMatch in quoted.allMatches(args)) {
      final name = quotedMatch.group(1)!.trim();
      if (name.isEmpty) continue;
      if (!out.contains(name)) out.add(name);
    }
  }
  return out;
}

/// Argument text of a parenthesised declaration (`consumerProguardFiles(...)`).
///
/// The opening parenthesis is part of the match, so the scan starts inside
/// the call: a declaration must never swallow the quoted strings that follow
/// it in the file.
String _balancedArguments(String rest) {
  var depth = 1;
  for (var i = 0; i < rest.length; i++) {
    final c = rest[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return rest.substring(0, i + 1);
    }
  }
  return rest;
}

/// Argument text of a space-separated declaration (`consumerProguardFiles 'a'`).
String _lineArguments(String rest) {
  final end = rest.indexOf('\n');
  return end == -1 ? rest : rest.substring(0, end);
}

/// Discovers the consumer ProGuard rule files a source plugin declares.
///
/// [moduleDir] is the plugin's Android module directory (the directory that
/// holds its `build.gradle`); Gradle resolves a declared file name relative
/// to it. The result lists the declared files that exist and the ones that do
/// not — a missing file is reported, never silently dropped.
PluginConsumerRuleDiscovery discoverPluginConsumerRuleFiles({
  required String pluginName,
  required String moduleDir,
}) {
  final declared = <String>[];
  for (final scriptName in pluginGradleScriptNames) {
    final script = File(p.join(moduleDir, scriptName));
    if (!script.existsSync()) continue;
    final text = script.readAsStringSync();
    for (final name in parseConsumerProguardFiles(text)) {
      if (!declared.contains(name)) declared.add(name);
    }
  }
  final files = <String>[];
  final missing = <String>[];
  for (final name in declared) {
    final resolved = p.normalize(p.join(moduleDir, name));
    if (File(resolved).existsSync()) {
      files.add(resolved);
    } else {
      missing.add(resolved);
    }
  }
  files.sort();
  missing.sort();
  return PluginConsumerRuleDiscovery(
    pluginName: pluginName,
    files: files,
    missing: missing,
  );
}

/// Collects the consumer rule files of every plugin, deterministically
/// ordered by plugin name and then by file path.
List<PluginConsumerRuleFile> collectPluginConsumerRuleFiles(
  Iterable<PluginConsumerRuleDiscovery> discoveries,
) {
  final out = <PluginConsumerRuleFile>[];
  final seen = <String>{};
  final ordered = discoveries.toList()
    ..sort((a, b) => a.pluginName.compareTo(b.pluginName));
  for (final discovery in ordered) {
    final files = discovery.files.toList()..sort();
    for (final file in files) {
      if (!seen.add('${discovery.pluginName}|$file')) continue;
      out.add(
        PluginConsumerRuleFile(
          pluginName: discovery.pluginName,
          path: file,
        ),
      );
    }
  }
  return out;
}
