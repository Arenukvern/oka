import 'dart:io';
import 'package:oka_core/oka_core.dart';

import 'package:path/path.dart' as p;

import '../../android_artifacts.dart';
import '../../android_state.dart';
import '../../auto_resolve.dart';
import '../../build/apk_layout.dart';
import '../../build/dependency_cache.dart';
import '../../build/host_codegen.dart';
import '../../build/launcher_icon.dart';
import '../../build/plugin_discovery.dart';
import '../../build/plugin_packager.dart';
import '../../build/sdk_locator.dart';
import '../../build_cache.dart';
import '../../manifest_spec.dart';
import '../toolchain.dart' show copyDirectory;
import 'asset_steps.dart' show DeeplinkConfig;

/// Ensures Android SDK packaging tools exist; fails loudly otherwise.
///
/// Preserves ADR-0001: never fall back to Gradle / `flutter build apk`.
class EnsureAndroidSdkStep extends BuildStep {

  EnsureAndroidSdkStep({final SdkLocator? sdkLocator})
    : sdkLocator = sdkLocator ?? SdkLocator();
  final SdkLocator sdkLocator;
  @override
  String get name => 'ensure-android-sdk';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    try {
      await sdkLocator.validatePackagingTools();
      return StepResult.success();
    } on Exception catch (e) {
      return StepResult.failure(
        'Android SDK / build-tools not available (required for no-Gradle APK '
        'packaging).\nDetails: $e\n'
        'Install Android command-line tools, then set ANDROID_SDK_ROOT or '
        'ANDROID_HOME.\nRun `oka doctor` for a full check. Oka does not use '
        'Gradle or `flutter build apk`.',
      );
    }
  }
}

/// Resolves target ABIs from config + CLI into [PipelineState.abis].
class ResolveAbisStep extends BuildStep {
  @override
  String get name => 'resolve-abis';

  @override
  Set<Artifact<Object>> get provides => {abis};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    state.abis = resolveAbis(
      configAbis: ctx.config.android.abis,
      targetAbi: ctx.targetAbi,
    );
    if (ctx.verbose) print('   ABIs: ${state.abis.join(', ')}');
    await Directory(ctx.buildDir).create(recursive: true);
    return StepResult.success();
  }
}

/// Discovers plugins and packages them (sources, jars, natives).
class PluginPackagingStep extends BuildStep {

  PluginPackagingStep({
    final SdkLocator? sdkLocator,
    final PluginDiscovery? pluginDiscovery,
    final DependencyCache? dependencyCache,
    this.strictPlugins = true,
    this.excludePlugins = const [],
  }) : sdkLocator = sdkLocator ?? SdkLocator(),
       pluginDiscovery = pluginDiscovery ?? PluginDiscovery(),
       dependencyCache = dependencyCache ?? DependencyCache();
  @override
  Set<Artifact<Object>> get provides => {packagedPlugins, registrations};

  final SdkLocator sdkLocator;
  final PluginDiscovery pluginDiscovery;
  final DependencyCache dependencyCache;
  final bool strictPlugins;

  /// Plugin names excluded from packaging (test-only plugins etc.).
  final List<String> excludePlugins;

  @override
  String get name => 'plugin-packaging';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    print('🔌 Discovering and packaging Flutter plugins...');
    var discovery = await pluginDiscovery.discover(ctx.projectPath);
    // ADR-0007: plugins contributed solely by dev_dependencies (e.g.
    // integration_test) ship nothing useful in a release artifact — exclude
    // them there, keep them in debug (flutter test uses them).
    var autoExcluded = <String>[];
    if (ctx.mode.isRelease) {
      autoExcluded = devDependencyNames(ctx.projectPath).toList();
    }
    // ADR-0010: constructor-level excludes win; pipeline-level overrides
    // (seeded by AndroidPipeline.run) fill the rest.
    final excluded = {
      ...excludePlugins,
      ...?state.pipelineOverrides?.excludePlugins,
      ...autoExcluded,
    };
    if (excluded.isNotEmpty) {
      discovery = discovery.excluding(excluded.toList());
      if (autoExcluded.isNotEmpty && ctx.verbose) {
        print('   auto-excluded dev-only plugins (release): '
            '${autoExcluded.join(', ')}');
      }
    }

    // Incremental: plugin packaging outputs are content-fingerprinted
    // (plugin sources + gradle files + pubspec graph). On a hit the whole
    // Maven/kotlinc-source resolution phase is skipped.
    final cache = StepCache(ctx.buildDir, verbose: ctx.verbose);
    await cache.load();
    final pluginFp = await fingerprintInputs([
      ...discovery.androidPlugins.expand(
        (final pl) => [
          ...filesUnder(pl.path, extension: '.kt'),
          ...filesUnder(pl.path, extension: '.java'),
          ...filesUnder(pl.path, extension: '.gradle'),
        ],
      ),
      if (File('${ctx.projectPath}/pubspec.yaml').existsSync())
        '${ctx.projectPath}/pubspec.yaml',
      if (File('${ctx.projectPath}/pubspec.lock').existsSync())
        '${ctx.projectPath}/pubspec.lock',
      if (File('${ctx.projectPath}/.dart_tool/package_config.json')
          .existsSync())
        '${ctx.projectPath}/.dart_tool/package_config.json',
    ], extras: [
      'plugins:${discovery.androidPlugins.map((final p) => '${p.name}:${p.pluginClass}').join(',')}',
      'abis:${state.abis.join(',')}',
      'strict:$strictPlugins',
    ]);
    final cached = cache.hit('plugin-packaging', pluginFp);
    if (cached != null) {
      print('🔌 plugin packaging: unchanged inputs — reusing packaged plugins');
      final names =
          (cached['plugin_names'] as List).cast<String>().toSet();
      final byName = {
        for (final p in discovery.androidPlugins) p.name: p,
      };
      if (names.every(byName.containsKey)) {
        final plugins = names.map((final n) {
          final pl = byName[n]!;
          return PackagedPlugin(
            plugin: pl,
            javaSources:
                ((cached['java_$n'] as List?) ?? const []).cast<String>(),
            kotlinSources:
                ((cached['kotlin_$n'] as List?) ?? const []).cast<String>(),
            jarDeps: ((cached['jars_$n'] as List?) ?? const []).cast<String>(),
            resDirs: ((cached['res_$n'] as List?) ?? const []).cast<String>(),
            manifestPaths:
                ((cached['man_$n'] as List?) ?? const []).cast<String>(),
          );
        }).toList();
        final natives = ((cached['natives'] as Map?) ?? const {})
            .cast<String, List<String>>();
        final result = PluginPackagingResult(
          plugins: plugins,
          failed: const [],
          registrations: (cached['registrations'] as List)
              .map((final e) => PluginRegistration(
                    className: (e as Map)['className'] as String,
                    name: e['name'] as String,
                  ))
              .toList(),
          allJavaSources: plugins.expand((final p) => p.javaSources).toList(),
          allKotlinSources: plugins.expand((final p) => p.kotlinSources).toList(),
          allJarDeps: plugins.expand((final p) => p.jarDeps).toSet().toList(),
          nativeLibsByAbi: natives,
          resDirs: plugins.expand((final p) => p.resDirs).toList(),
          manifestPaths: plugins.expand((final p) => p.manifestPaths).toList(),
        );
        state.pluginDiscovery = discovery;
        state.packagedPlugins = result;
        state.registrations = result.registrations;
        return StepResult.success();
      }
      if (ctx.verbose) print('   cache stale: plugin set changed');
    }
    final support = decidePluginSupport(discovery, strict: strictPlugins);
    if (!support.allowBuild) {
      pluginDiscovery.ensureSupported(discovery);
    }
    if (support.softMode && support.warnings.isNotEmpty) {
      print('⚠️  Soft plugin mode — skipping unsupported plugins:');
      for (final w in support.warnings) {
        print('   - $w');
      }
    }

    final packager = PluginPackager(
      dependencyCache: dependencyCache,
      sdkLocator: sdkLocator,
      verbose: ctx.verbose,
    );
    final packaged = await packager.packageAll(
      discovery,
      buildDir: ctx.buildDir,
      abis: state.abis,
      requireAll: strictPlugins,
    );
    if (packaged.failed.isNotEmpty && strictPlugins) {
      final msg = packaged.failed
          .map((final f) => '${f.plugin.name}: ${f.failureReason}')
          .join('\n  - ');
      return StepResult.failure(
        'Failed to package required plugins for no-Gradle APK:\n  - $msg',
      );
    }
    if (packaged.failed.isNotEmpty && !strictPlugins) {
      for (final f in packaged.failed) {
        print(
          '⚠️  Skipping unpackageable plugin ${f.plugin.name}: '
          '${f.failureReason}',
        );
      }
    }

    final registrations = packaged.registrations;
    if (registrations.isEmpty &&
        discovery.androidPlugins.any((final p) => p.pluginClass != null)) {
      return StepResult.failure(
        'GeneratedPluginRegistrant would be empty but Android plugins with '
        'pluginClass were discovered. Plugin packaging failed to produce '
        'registrations.',
      );
    }
    print(
      '   Plugins (Android): ${discovery.androidPlugins.length} '
      '(registrations: ${registrations.length}, '
      'failed: ${packaged.failed.length})',
    );

    state.pluginDiscovery = discovery;
    state.packagedPlugins = packaged;
    state.registrations = registrations;
    // Persist for incremental reuse (per-plugin lists + aggregate natives).
    final persisted = <String, dynamic>{
      'registrations': registrations
          .map((final r) => {'className': r.className, 'name': r.name})
          .toList(),
      'plugin_names': packaged.plugins.map((final p) => p.plugin.name).toList(),
      'natives': packaged.nativeLibsByAbi,
    };
    for (final p in packaged.plugins) {
      persisted['java_${p.plugin.name}'] = p.javaSources;
      persisted['kotlin_${p.plugin.name}'] = p.kotlinSources;
      persisted['jars_${p.plugin.name}'] = p.jarDeps;
      persisted['res_${p.plugin.name}'] = p.resDirs;
      persisted['man_${p.plugin.name}'] = p.manifestPaths;
    }
    await cache.store('plugin-packaging', pluginFp, persisted);
    return StepResult.success();
  }
}

/// Generates MainActivity, GeneratedPluginRegistrant, manifest and minimal res.
///
/// The manifest is rendered from a typed [ManifestSpec] (ADR-0006). Sources
/// for the spec, in override order (later wins):
///
/// 1. oka.yaml `pipeline.deeplinks` (legacy fast-settings) merge in
/// 2. oka.yaml `android.manifest:` (typed surface)
/// 3. [manifestOverride] from Dart-composed pipelines wins over both
class HostCodegenStep extends BuildStep {

  HostCodegenStep({
    this.manifestOverride,
    this.yamlDeeplinks = const [],
    this.resDirs = const [],
    final IconConfig? iconConfig,
  }) : iconConfig = iconConfig ?? const IconConfig();
  @override
  Set<Artifact<Object>> get requires => {registrations};

  @override
  Set<Artifact<Object>> get provides => {hostDir};

  /// Launcher icon configuration (adaptive, vector-first).
  final IconConfig iconConfig;

  /// Optional typed manifest override composed by hooks/Dart pipelines.
  /// When non-null it replaces the YAML-derived spec entirely (composition,
  /// not accumulation); use [ManifestSpec.copyWith] upstream to extend YAML.
  final ManifestSpec? manifestOverride;

  /// User res dirs merged into the generated res tree (themes, splash,
  /// mipmaps). Copied AFTER generated res so user resources win.
  final List<String> resDirs;

  @override
  String get name => 'host-codegen';

  /// Deeplinks from oka.yaml `pipeline.deeplinks` fast-settings (legacy
  /// surface, merged into the spec when the typed manifest doesn't declare
  /// its own).
  final List<DeeplinkConfig> yamlDeeplinks;

  /// ADR-0010: values left at constructor defaults fall back to the
  /// pipeline-level overrides seeded into the runtime scope.
  ({
    List<DeeplinkConfig> deeplinks,
    IconConfig iconConfig,
    ManifestSpec? manifestOverride,
    List<String> resDirs,
  }) _resolveHostOverrides(final PipelineState state) {
    final ov = state.pipelineOverrides;
    return (
      deeplinks: yamlDeeplinks.isNotEmpty
          ? yamlDeeplinks
          : (ov?.deeplinks ?? const []),
      iconConfig: iconConfig == const IconConfig()
          ? (ov?.icon ?? const IconConfig())
          : iconConfig,
      manifestOverride: manifestOverride ?? ov?.manifest,
      resDirs: resDirs.isNotEmpty ? resDirs : (ov?.resDirs ?? const []),
    );
  }

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    print('📝 Generating Android host sources...');
    final host = _resolveHostOverrides(state);
    final hostDir = p.join(ctx.buildDir, 'host_java');
    final packageName = ctx.config.android.packageName;

    final mainRel = mainActivityRelativePath(packageName);
    final mainPath = p.join(hostDir, mainRel);
    await File(mainPath).parent.create(recursive: true);
    await File(mainPath).writeAsString(generateMainActivityJava(packageName));

    final registrantPath = p.join(
      hostDir,
      'io',
      'flutter',
      'plugins',
      'GeneratedPluginRegistrant.java',
    );
    await File(registrantPath).parent.create(recursive: true);
    await File(
      registrantPath,
    ).writeAsString(generatePluginRegistrantJava(state.registrations));

    // Minimal res for aapt2 — values + launcher icon resources.
    final resDir = p.join(ctx.buildDir, 'res');
    await Directory(p.join(resDir, 'values')).create(recursive: true);
    await File(p.join(resDir, 'values', 'strings.xml')).writeAsString('''
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">${ctx.config.name.isEmpty ? 'App' : ctx.config.name}</string>
</resources>
''');

    // User res dirs (launch theme, styles, splash, mipmaps) — merged after
    // generated res so user resources win on conflicts.
    for (final rel in host.resDirs) {
      final src = Directory(p.join(ctx.projectPath, rel));
      if (!await src.exists()) {
        return StepResult.failure('res_dirs: directory not found: $rel');
      }
      await copyDirectory(src, Directory(resDir));
      if (ctx.verbose) print('   merged res dir: $rel');
    }

    // Launcher icon (adaptive, vector-first — see launcher_icon.dart).
    String iconRef = '';
    final hasUserIcon = await _hasUserLauncherIcon(resDir);
    if (hasUserIcon && _isDefaultIconConfig(host.iconConfig)) {
      // User res dirs already provide the launcher icon (e.g. migrated
      // projects shipping real mipmap PNGs). Generating oka's default
      // adaptive icon would override them on API 26+ (anydpi-v26 wins).
      iconRef = '@mipmap/ic_launcher';
      // Remove any oka-generated icon artifacts from earlier builds — they
      // would otherwise shadow the user's icon (anydpi-v26 wins on API 26+).
      for (final rel in const [
        'drawable/ic_launcher_foreground.xml',
        'drawable/ic_launcher_monochrome.xml',
        'values/ic_launcher_background.xml',
        'mipmap-anydpi-v26/ic_launcher.xml',
      ]) {
        final stale = File(p.join(resDir, rel));
        if (await stale.exists()) await stale.delete();
      }
      if (ctx.verbose) {
        print('   icon: using user-supplied launcher icon from res dirs');
      }
    } else {
      try {
        final icons = await stageLauncherIcons(
          resDir,
          host.iconConfig,
          projectPath: ctx.projectPath,
        );
        iconRef = icons.manifestRef;
        if (ctx.verbose) {
          print('   icon resources: ${icons.written.join(', ')}');
        }
      } on Exception catch (e) {
        return StepResult.failure('launcher icon: $e');
      }
    }

    // Typed manifest spec: YAML `android.manifest:` is the declarative
    // base; pipeline fast-settings deeplinks merge in; [manifestOverride]
    // from a Dart-composed pipeline wins over both.
    final androidYaml = ctx.config.toJson()['android'];
    final manifestYaml = androidYaml is Map ? androidYaml['manifest'] : null;
    var spec = manifestYaml is Map
        ? ManifestSpec.fromYamlMap(manifestYaml)
        : const ManifestSpec();
    if (host.deeplinks.isNotEmpty) {
      spec = spec.copyWith(deeplinks: host.deeplinks);
    }
    final effective = host.manifestOverride ?? spec;
    if (ctx.verbose) {
      print(
        '   manifest: ${effective.permissions.length} permissions, '
        '${effective.deeplinks.length} deeplinks, '
        'cleartext=${effective.cleartextTraffic}',
      );
    }

    final manifest = generateAndroidManifestFromSpec(
      packageName: packageName,
      label: ctx.config.name.isEmpty ? packageName : ctx.config.name,
      minSdk: ctx.config.android.minSdk.isEmpty
          ? '21'
          : ctx.config.android.minSdk,
      targetSdk: ctx.config.android.targetSdk.isEmpty
          ? '34'
          : ctx.config.android.targetSdk,
      spec: effective,
      iconRef: iconRef,
    );
    await File(
      p.join(ctx.buildDir, 'AndroidManifest.xml'),
    ).writeAsString(manifest);

    state.hostDir = hostDir;
    return StepResult.success();
  }
}

/// Whether the merged res tree already defines a launcher icon (any
/// `mipmap*/ic_launcher.*`, e.g. migrated projects shipping real PNGs).
Future<bool> _hasUserLauncherIcon(final String resDir) async {
  final dir = Directory(resDir);
  if (!await dir.exists()) return false;
  await for (final e in dir.list()) {
    if (e is! Directory) continue;
    if (!p.basename(e.path).startsWith('mipmap')) continue;
    await for (final f in e.list()) {
      if (p.basename(f.path).startsWith('ic_launcher')) return true;
    }
  }
  return false;
}

/// True when no icon fast-settings are configured (all defaults) — used to
/// let user-supplied launcher icons win over oka's generated glyph.
bool _isDefaultIconConfig(final IconConfig c) =>
    c.vector.isEmpty &&
    c.monochrome.isEmpty &&
    c.backgroundColor == '#FFFFFF';
