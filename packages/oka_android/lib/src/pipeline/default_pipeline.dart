export '../pipeline_overrides.dart';

import '../pipeline_overrides.dart';

import 'package:oka_core/src/config/maven_coordinate.dart';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../build/apk_layout.dart';
import '../build/dependency_cache.dart';
import '../build/flutter_assemble.dart';
import '../build/plugin_discovery.dart';
import '../build/sdk_locator.dart';
import 'package:oka_core/src/config/build_context.dart';
import 'package:oka_core/src/pipeline/pipeline.dart';

import '../android_artifacts.dart';
import '../android_state.dart';
import '../post_build_lint.dart';
import 'steps/asset_steps.dart';
import 'steps/flutter_steps.dart';
import 'steps/host_steps.dart';
import 'steps/tool_steps.dart';


/// Resolves user-declared extra Maven coordinates into
/// [PipelineState.extraRuntimeJars] before compile/dex.
class ExtraDepsStep extends BuildStep {
  @override
  Set<Artifact<Object>> get provides => {extraRuntimeJars};

  final List<String> coordinates;
  final DependencyCache cache;
  final bool verbose;

  @override
  String get name => 'extra-deps';

  ExtraDepsStep(this.coordinates, this.cache, {this.verbose = false});

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    // ADR-0010: constructor coordinates win; pipeline-level overrides fill in.
    final effective = coordinates.isNotEmpty
        ? coordinates
        : (state.pipelineOverrides?.extraDeps ?? const <String>[]);
    if (effective.isEmpty) return StepResult.success();
    print('📚 Resolving ${coordinates.length} extra dependencies...');
    final jars = <String>[];
    for (final coord in effective) {
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
class LocalAarsStep extends BuildStep {
  @override
  Set<Artifact<Object>> get provides => {aarNativeLibsByAbi, aarResDirs};

  final List<String> aarPaths;
  final bool verbose;

  @override
  String get name => 'local-aars';

  LocalAarsStep(this.aarPaths, {this.verbose = false});

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    // ADR-0010: constructor paths win; pipeline-level overrides fill in.
    final effective = aarPaths.isNotEmpty
        ? aarPaths
        : (state.pipelineOverrides?.localAars ?? const <String>[]);
    if (effective.isEmpty) return StepResult.success();
    print('📦 Processing ${aarPaths.length} local AAR file(s)...');
    final jars = <String>[...state.extraRuntimeJars];
    final natives = <String, List<String>>{};
    final resDirs = <String>[];

    for (final rel in effective) {
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
    ExtraDepsStep(overrides.extraDeps, cache, verbose: verbose),
    LocalAarsStep(overrides.localAars, verbose: verbose),
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
    ExtraDepsStep(overrides.extraDeps, cache, verbose: verbose),
    LocalAarsStep(overrides.localAars, verbose: verbose),
    CompileProtoAndDexStep(sdkLocator: sdkLocator, resourceConfigs: overrides.resourceConfigs),
    ExtraAssetsStep(overrides.extraAssets),
    PackageAndSignAabStep(sdkLocator: sdkLocator, signing: overrides.signing),
    ValidateAabLayoutStep(),
    PostBuildLintStep(maxSizeMb: overrides.maxSizeMb),
  ], verbose: verbose);
}

