import 'package:oka_core/src/config/maven_coordinate.dart';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../build/apk_layout.dart';
import '../build/dependency_cache.dart';
import '../build/flutter_assemble.dart';
import '../build/launcher_icon.dart';
import '../build/plugin_discovery.dart';
import '../build/sdk_locator.dart';
import 'package:oka_core/src/config/build_context.dart';
import 'package:oka_core/src/pipeline/pipeline.dart';

import '../android_artifacts.dart';
import '../android_state.dart';
import '../manifest_spec.dart';
import '../post_build_lint.dart';
import '../signing_config.dart';
import 'steps/asset_steps.dart';
import 'steps/flutter_steps.dart';
import 'steps/host_steps.dart';
import 'steps/tool_steps.dart';

/// Fast-settings parsed from `oka.yaml` `pipeline:` section.
///
/// Precedence: built-in defaults < `oka.yaml` pipeline section < Dart
/// composition (a user-supplied [Pipeline] always wins).
class PipelineOverrides {
  /// Extra Maven coordinates (`group:artifact:version`) merged into the
  /// runtime dependency set. The main escape hatch for missing-dependency
  /// gaps without editing oka.
  final List<String> extraDeps;

  /// Extra asset sources merged into flutter_assets (files or dirs).
  final List<({String from, String to})> extraAssets;

  /// Deeplink declarations rendered as manifest intent-filters.
  final List<DeeplinkConfig> deeplinks;

  /// Launcher icon configuration (adaptive, vector-first).
  final IconConfig icon;

  /// Local AAR files (project-relative paths) to package into the APK.
  final List<String> localAars;

  /// Resource qualifier filter (aapt2 `--configs`), e.g. `['en', 'ru']`.
  final List<String> resourceConfigs;

  /// Release signing configuration (null → key.properties → debug fallback).
  final SigningConfig? signing;

  /// Typed manifest override (ADR-0006). Null → YAML `android.manifest:`
  /// only; non-null wins over YAML.
  final ManifestSpec? manifest;

  /// User Android res dirs (project-relative) merged into the generated
  /// res tree before aapt2 (launch themes, styles, splash drawables,
  /// mipmap icons). Parsed from `android.res_dirs`.
  final List<String> resDirs;

  /// Plugins excluded from packaging (e.g. test-only `integration_test`).
  final List<String> excludePlugins;

  /// Artifact size budget in MB — post-build lint fails when exceeded.
  final int? maxSizeMb;

  const PipelineOverrides({
    this.extraDeps = const [],
    this.extraAssets = const [],
    this.deeplinks = const [],
    this.icon = const IconConfig(),
    this.localAars = const [],
    this.resourceConfigs = const [],
    this.signing,
    this.manifest,
    this.resDirs = const [],
    this.excludePlugins = const [],
    this.maxSizeMb,
  });

  /// Typed-override helper for Dart composition (ADR-0006). Example:
  /// `overrides.copyWith(resourceConfigs: ['en', 'ru'])`.
  PipelineOverrides copyWith({
    List<String>? extraDeps,
    List<({String from, String to})>? extraAssets,
    List<DeeplinkConfig>? deeplinks,
    IconConfig? icon,
    List<String>? localAars,
    List<String>? resourceConfigs,
    SigningConfig? signing,
    ManifestSpec? manifest,
    List<String>? resDirs,
    List<String>? excludePlugins,
    int? maxSizeMb,
  }) => PipelineOverrides(
    extraDeps: extraDeps ?? this.extraDeps,
    extraAssets: extraAssets ?? this.extraAssets,
    deeplinks: deeplinks ?? this.deeplinks,
    icon: icon ?? this.icon,
    localAars: localAars ?? this.localAars,
    resourceConfigs: resourceConfigs ?? this.resourceConfigs,
    signing: signing ?? this.signing,
    manifest: manifest ?? this.manifest,
    resDirs: resDirs ?? this.resDirs,
    excludePlugins: excludePlugins ?? this.excludePlugins,
    maxSizeMb: maxSizeMb ?? this.maxSizeMb,
  );

  factory PipelineOverrides.fromYamlMap(Map<dynamic, dynamic> map) {
    final deps = map['extra_deps'];
    final assetsRaw = map['extra_assets'];
    final linksRaw = map['deeplinks'];
    final iconRaw = map['icon'];
    final aarsRaw = map['local_aars'];
    return PipelineOverrides(
      extraDeps: deps is List ? deps.map((e) => e.toString()).toList() : [],
      extraAssets: assetsRaw is List
          ? ExtraAssetsStep.parse(assetsRaw)
          : const [],
      deeplinks: linksRaw is List ? DeeplinkConfig.parse(linksRaw) : const [],
      icon: iconRaw is Map ? IconConfig.fromMap(iconRaw) : const IconConfig(),
      localAars: aarsRaw is List
          ? aarsRaw.map((e) => e.toString()).toList()
          : const [],
      resourceConfigs: _resourceConfigs(map['resource_configs']),
      excludePlugins:
          map['exclude_plugins'] is List
          ? (map['exclude_plugins'] as List).map((e) => e.toString()).toList()
          : const [],
      maxSizeMb: map['max_size_mb'] is int ? map['max_size_mb'] as int : null,
    );
  }

  /// Merges `android:` section surfaces that are not `pipeline:`-scoped.
  static PipelineOverrides fromOkaYaml(Map<dynamic, dynamic> doc) {
    final pipelineRaw = doc['pipeline'];
    final base = pipelineRaw is Map
        ? PipelineOverrides.fromYamlMap(pipelineRaw)
        : const PipelineOverrides();
    final android = doc['android'];
    final resRaw = android is Map ? android['res_dirs'] : null;
    final resDirs = resRaw is List
        ? resRaw.map((e) => e.toString()).toList(growable: false)
        : const <String>[];
    return resDirs.isEmpty ? base : base.copyWith(resDirs: resDirs);
  }


  static List<String> _resourceConfigs(dynamic raw) =>
      raw is List ? raw.map((e) => e.toString()).toList() : const [];

  static Future<PipelineOverrides> load(String projectPath) async {
    final file = File(p.join(projectPath, 'oka.yaml'));
    if (!await file.exists()) return const PipelineOverrides();
    try {
      final doc = loadYaml(await file.readAsString());
      if (doc is! Map) return const PipelineOverrides();
      return PipelineOverrides.fromOkaYaml(Map<dynamic, dynamic>.from(doc));
    } on YamlException {
      return const PipelineOverrides();
    }
  }
}

/// Builds the default no-Gradle APK pipeline (ADR-0002).
///
/// Step order mirrors the historical FlutterApkBuilder.build() exactly —
/// this is a behavior-preserving composition.
Future<Pipeline> defaultApkPipeline(
  SdkLocator sdkLocator, {
  bool verbose = false,
  bool layoutOnly = false,
  bool strictPlugins = true,
  bool allowNetwork = true,
  DependencyCache? dependencyCache,
  PipelineOverrides overrides = const PipelineOverrides(),
}) async {
  final cache =
      dependencyCache ??
      DependencyCache(verbose: verbose, allowNetwork: allowNetwork);
  final assembler = FlutterAssembler(verbose: verbose);
  final discovery = PluginDiscovery(verbose: verbose);

  // Layout-only test path keeps the old shortcut semantics.
  if (layoutOnly) {
    return Pipeline([_LayoutOnlyStep(sdkLocator)], verbose: verbose);
  }

  return Pipeline([
    EnsureAndroidSdkStep(sdkLocator: sdkLocator),
    ResolveAbisStep(),
    PluginPackagingStep(
      sdkLocator: sdkLocator,
      pluginDiscovery: discovery,
      dependencyCache: cache,
      strictPlugins: strictPlugins,
      excludePlugins: overrides.excludePlugins,
    ),
    HostCodegenStep(
      yamlDeeplinks: overrides.deeplinks,
      iconConfig: overrides.icon,
      manifestOverride: overrides.manifest,
      resDirs: overrides.resDirs,
    ),
    FlutterAssembleStep(sdkLocator: sdkLocator, assembler: assembler),
    EngineExtractionStep(sdkLocator: sdkLocator),
    ReleaseAotStep(sdkLocator: sdkLocator, assembler: assembler),
    DependencyResolveStep(cache: cache),
    _ExtraDepsStep(overrides.extraDeps, cache, verbose: verbose),
    _LocalAarsStep(overrides.localAars, verbose: verbose),
    CompileAndDexStep(sdkLocator: sdkLocator, resourceConfigs: overrides.resourceConfigs),
    ExtraAssetsStep(overrides.extraAssets),
    PackageAndSignStep(sdkLocator: sdkLocator, signing: overrides.signing),
    ValidateLayoutStep(),
    PostBuildLintStep(maxSizeMb: overrides.maxSizeMb),
  ], verbose: verbose);
}

/// Builds the default no-Gradle AAB pipeline (ADR-0004).
///
/// Shares steps 1–10 with the APK pipeline; diverges at resource linking
/// (`--proto-format`), packaging (`base/` module + jarsigner v1) and layout
/// validation.
Future<Pipeline> defaultAabPipeline(
  SdkLocator sdkLocator, {
  bool verbose = false,
  bool strictPlugins = true,
  bool allowNetwork = true,
  DependencyCache? dependencyCache,
  PipelineOverrides overrides = const PipelineOverrides(),
}) async {
  final cache =
      dependencyCache ??
      DependencyCache(verbose: verbose, allowNetwork: allowNetwork);
  final assembler = FlutterAssembler(verbose: verbose);
  final discovery = PluginDiscovery(verbose: verbose);

  return Pipeline([
    EnsureAndroidSdkStep(sdkLocator: sdkLocator),
    ResolveAbisStep(),
    PluginPackagingStep(
      sdkLocator: sdkLocator,
      pluginDiscovery: discovery,
      dependencyCache: cache,
      strictPlugins: strictPlugins,
      excludePlugins: overrides.excludePlugins,
    ),
    HostCodegenStep(
      yamlDeeplinks: overrides.deeplinks,
      iconConfig: overrides.icon,
      manifestOverride: overrides.manifest,
      resDirs: overrides.resDirs,
    ),
    FlutterAssembleStep(sdkLocator: sdkLocator, assembler: assembler),
    EngineExtractionStep(sdkLocator: sdkLocator),
    ReleaseAotStep(sdkLocator: sdkLocator, assembler: assembler),
    DependencyResolveStep(cache: cache),
    _ExtraDepsStep(overrides.extraDeps, cache, verbose: verbose),
    _LocalAarsStep(overrides.localAars, verbose: verbose),
    CompileProtoAndDexStep(sdkLocator: sdkLocator, resourceConfigs: overrides.resourceConfigs),
    ExtraAssetsStep(overrides.extraAssets),
    PackageAndSignAabStep(sdkLocator: sdkLocator, signing: overrides.signing),
    ValidateAabLayoutStep(),
    PostBuildLintStep(maxSizeMb: overrides.maxSizeMb),
  ], verbose: verbose);
}

/// Resolves user-declared extra Maven coordinates into
/// [PipelineState.extraRuntimeJars] before compile/dex.
class _ExtraDepsStep extends BuildStep {
  @override
  Set<Artifact<Object>> get provides => {extraRuntimeJars};

  final List<String> coordinates;
  final DependencyCache cache;
  final bool verbose;

  @override
  String get name => 'extra-deps';

  _ExtraDepsStep(this.coordinates, this.cache, {this.verbose = false});

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    if (coordinates.isEmpty) return StepResult.success();
    print('📚 Resolving ${coordinates.length} extra dependencies...');
    final jars = <String>[];
    for (final coord in coordinates) {
      final parsed = MavenCoordinate.parse(coord);
      if (parsed == null) {
        return StepResult.failure(
          'Invalid extra_dep coordinate "$coord" — expected '
          '"group:artifact:version".',
        );
      }
      try {
        final jar = await cache.resolve(parsed);
        jars.add(jar.jarPath);
        if (verbose) print('   $coord → ${jar.jarPath}');
      } on Exception catch (e) {
        return StepResult.failure(
          'Failed to resolve extra dependency "$coord": $e\n'
          'Check group/artifact/version and network access.',
        );
      }
    }
    state.extraRuntimeJars = jars;
    return StepResult.success();
  }
}

/// Processes local AAR files declared in `pipeline.local_aars`.
///
/// Extracts classes.jar (for dexing), jni natives, and res into the build dir;
/// results land in [PipelineState.extraRuntimeJars], `aarNativeLibsByAbi`, and
/// `aarResDirs` for downstream compile/package steps.
class _LocalAarsStep extends BuildStep {
  @override
  Set<Artifact<Object>> get provides => {aarNativeLibsByAbi, aarResDirs};

  final List<String> aarPaths;
  final bool verbose;

  @override
  String get name => 'local-aars';

  _LocalAarsStep(this.aarPaths, {this.verbose = false});

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    if (aarPaths.isEmpty) return StepResult.success();
    print('📦 Processing ${aarPaths.length} local AAR file(s)...');
    final jars = <String>[...state.extraRuntimeJars];
    final natives = <String, List<String>>{};
    final resDirs = <String>[];

    for (final rel in aarPaths) {
      final aarFile = File(p.join(ctx.projectPath, rel));
      if (!await aarFile.exists()) {
        return StepResult.failure('local_aars: file not found: $rel');
      }
      if (!rel.toLowerCase().endsWith('.aar')) {
        return StepResult.failure('local_aars: "$rel" is not an .aar file');
      }
      final bytes = await aarFile.readAsBytes();
      final workDir = p.join(
        ctx.buildDir,
        'local_aars',
        p.basename(rel).replaceAll('.aar', ''),
      );

      // classes.jar → dex input
      final classes = tryExtractClassesJarFromAar(bytes);
      if (classes != null) {
        final jarPath = p.join(workDir, 'classes.jar');
        await File(jarPath).parent.create(recursive: true);
        await File(jarPath).writeAsBytes(classes, flush: true);
        jars.add(jarPath);
      } else if (verbose) {
        print('   ⚠️  $rel has no classes.jar (resource-only AAR?)');
      }

      // natives + res
      final payload = await extractAarPayload(bytes, workDir, verbose: verbose);
      payload.nativeLibsByAbi.forEach((abi, paths) {
        natives.putIfAbsent(abi, () => []).addAll(paths);
      });
      resDirs.addAll(payload.resDirs);
      if (verbose) print('   $rel processed');
    }

    state.extraRuntimeJars = jars;
    state.aarNativeLibsByAbi = natives;
    state.aarResDirs = resDirs;
    return StepResult.success();
  }
}

/// Layout-only staging used by unit tests (no external tools invoked).
class _LayoutOnlyStep extends BuildStep {
  @override
  Set<Artifact<Object>> get provides => {abis, apkPath};

  final SdkLocator sdkLocator;

  @override
  String get name => 'layout-only';

  _LayoutOnlyStep(this.sdkLocator);

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    final abis = resolveAbis(
      configAbis: ctx.config.android.abis,
      targetAbi: ctx.targetAbi,
    );
    state.abis = abis;
    await Directory(ctx.buildDir).create(recursive: true);

    final fakeDex = p.join(ctx.buildDir, 'classes.dex');
    await File(fakeDex).writeAsBytes([0x64, 0x65, 0x78, 0x0a]); // "dex\n"
    final staging = p.join(ctx.buildDir, 'staging');
    await stageApkLayout(
      stagingDir: staging,
      dexFile: fakeDex,
      flutterAssetsDir: p.join(ctx.buildDir, 'assemble', 'flutter_assets'),
      libflutterByAbi: {
        for (final abi in abis)
          normalizeAbi(abi): p.join(
            ctx.buildDir,
            'lib',
            normalizeAbi(abi),
            'libflutter.so',
          ),
      },
    );
    final apkPath = p.join(ctx.buildDir, 'app-${ctx.mode.name}.apk');
    await zipStagingToApk(staging, apkPath);
    state.apkPath = apkPath;
    return StepResult.success();
  }
}
