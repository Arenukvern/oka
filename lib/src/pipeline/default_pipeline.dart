import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../build/apk_layout.dart';
import '../build/dependency_cache.dart';
import '../build/flutter_assemble.dart';
import '../build/plugin_discovery.dart';
import '../build/sdk_locator.dart';
import '../config/build_context.dart';
import 'pipeline.dart';
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

  const PipelineOverrides({
    this.extraDeps = const [],
    this.extraAssets = const [],
    this.deeplinks = const [],
  });

  factory PipelineOverrides.fromYamlMap(Map<dynamic, dynamic> map) {
    final deps = map['extra_deps'];
    final assetsRaw = map['extra_assets'];
    final linksRaw = map['deeplinks'];
    return PipelineOverrides(
      extraDeps: deps is List ? deps.map((e) => e.toString()).toList() : [],
      extraAssets: assetsRaw is List
          ? ExtraAssetsStep.parse(assetsRaw)
          : const [],
      deeplinks: linksRaw is List ? DeeplinkConfig.parse(linksRaw) : const [],
    );
  }

  static Future<PipelineOverrides> load(String projectPath) async {
    final file = File(p.join(projectPath, 'oka.yaml'));
    if (!await file.exists()) return const PipelineOverrides();
    try {
      final doc = loadYaml(await file.readAsString());
      if (doc is! Map) return const PipelineOverrides();
      final pipeline = doc['pipeline'];
      if (pipeline is! Map) return const PipelineOverrides();
      return PipelineOverrides.fromYamlMap(pipeline);
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
    EnsureAndroidSdkStep(sdkLocator),
    ResolveAbisStep(),
    PluginPackagingStep(
      sdkLocator: sdkLocator,
      pluginDiscovery: discovery,
      dependencyCache: cache,
      strictPlugins: strictPlugins,
    ),
    HostCodegenStep(deeplinks: overrides.deeplinks),
    FlutterAssembleStep(sdkLocator: sdkLocator, assembler: assembler),
    EngineExtractionStep(sdkLocator),
    ReleaseAotStep(sdkLocator: sdkLocator, assembler: assembler),
    DependencyResolveStep(cache),
    _ExtraDepsStep(overrides.extraDeps, cache, verbose: verbose),
    CompileAndDexStep(sdkLocator),
    ExtraAssetsStep(overrides.extraAssets),
    PackageAndSignStep(sdkLocator),
    ValidateLayoutStep(),
  ], verbose: verbose);
}

/// Resolves user-declared extra Maven coordinates into
/// [PipelineState.extraRuntimeJars] before compile/dex.
class _ExtraDepsStep implements BuildStep {
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

/// Layout-only staging used by unit tests (no external tools invoked).
class _LayoutOnlyStep implements BuildStep {
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
