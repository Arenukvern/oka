import 'dart:io';
import 'package:oka_core/oka_core.dart';

import 'package:path/path.dart' as p;

import '../android_artifacts.dart';
import '../android_state.dart';
import '../build/apk_layout.dart';
import '../build/dependency_cache.dart';
import '../build/flutter_assemble.dart';
import '../build/plugin_discovery.dart';
import '../build/toolchain.dart';
import '../compilation/bytecode_compilation.dart' show compareMavenVersions;
import '../dev/run_session.dart';
import '../pipeline_overrides.dart';
import '../post_build_lint.dart';
import 'steps/asset_steps.dart';
import 'steps/flutter_steps.dart';
import 'steps/host_steps.dart';
import 'steps/tool_steps.dart';

export '../pipeline_overrides.dart';

/// Resolves user-declared extra Maven coordinates — including their POM
/// transitive closure and AAR payloads — into [PipelineState.extraRuntimeJars],
/// `aarNativeLibsByAbi`, and `aarResDirs` before compile/package.
///
/// Transitive resolution matches plugin packaging (ADR-0008): host code
/// compiled against an extra dep needs its dependencies on the classpath
/// (e.g. `tasks-vision` without `tasks-core` fails with "cannot access …
/// supertype"), and AAR natives must reach the APK or the app crashes at
/// runtime with `UnsatisfiedLinkError`.
class ExtraDepsStep extends BuildStep {
  ExtraDepsStep(this.coordinates, this.cache, {this.verbose = false});
  @override
  Set<Artifact<Object>> get provides => {extraRuntimeJars};

  final List<String> coordinates;
  final DependencyCache cache;
  final bool verbose;

  @override
  String get name => 'extra-deps';

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    // ADR-0010: constructor coordinates win; pipeline-level overrides fill in.
    final effective = coordinates.isNotEmpty
        ? coordinates
        : (state.pipelineOverrides?.extraDeps ?? const <String>[]);
    if (effective.isEmpty) return StepResult.success();
    print('📚 Resolving ${effective.length} extra dependencies...');
    final roots = <MavenCoordinate>[];
    for (final coord in effective) {
      final parsed = MavenCoordinate.parse(coord);
      if (parsed == null) {
        return StepResult.failure(
          'Invalid extra_dep coordinate "$coord" — expected '
          '"group:artifact:version".',
        );
      }
      roots.add(parsed);
    }
    // Root artifacts fail hard: a typo'd extra_dep must stop the build, not
    // surface later as missing classes on the compile classpath.
    final byJarPath = <String, ResolvedJar>{};
    try {
      for (final root in roots) {
        final jar = await cache.resolve(root);
        byJarPath[jar.jarPath] = jar;
        if (verbose) print('   ${root.coordinate} → ${jar.jarPath}');
      }
    } on Exception catch (e) {
      return StepResult.failure(
        'Failed to resolve extra dependency: $e\n'
        'Check group/artifact/version and network access.',
      );
    }
    // POM transitive closure — the same policy plugin packaging uses, so
    // extra deps and plugin deps cannot disagree on classpath depth. Root
    // payloads come from the direct resolves above: the BFS drops a resolved
    // artifact when only its POM fetch fails (offline warm-cache builds).
    final transitives = await cache.resolveWithTransitives(roots);
    for (final jar in transitives) {
      byJarPath.putIfAbsent(jar.jarPath, () => jar);
    }
    // Gradle-style highest-version-wins across the whole graph: the AndroidX
    // embedding set (dependency-resolve) participates in selection so a
    // POM-pinned old androidx.core (e.g. 1.1.0 under camera-core) never
    // contributes res/natives when a newer version is already resolved —
    // payloads come from the same version whose classes are on the classpath.
    final embedding = <ResolvedJar>[...state.androidxJars];
    final embeddingPaths = embedding.map((final jar) => jar.jarPath).toSet();
    final selected = _selectLatestByArtifact([
      ...embedding,
      ...byJarPath.values,
    ]);
    final natives = <String, List<String>>{...state.aarNativeLibsByAbi};
    final resDirs = <String>[...state.aarResDirs];
    for (final jar in selected) {
      jar.nativeLibsByAbi.forEach((final abi, final paths) {
        natives.putIfAbsent(normalizeAbi(abi), () => []).addAll(paths);
      });
      for (final dir in jar.resDirs) {
        if (!resDirs.contains(dir)) resDirs.add(dir);
      }
    }
    // Embedding-set winners are already on the classpath via androidxJars;
    // only genuinely extra artifacts become extra runtime jars.
    state.extraRuntimeJars = selected
        .where((final jar) => !embeddingPaths.contains(jar.jarPath))
        .map((final jar) => jar.jarPath)
        .toList();
    state.aarNativeLibsByAbi = natives;
    state.aarResDirs = resDirs;
    return StepResult.success();
  }
}

/// Picks the highest resolved version per `groupId:artifactId`, keeping the
/// result order deterministic (sorted by jar path).
List<ResolvedJar> _selectLatestByArtifact(final Iterable<ResolvedJar> jars) {
  final best = <String, ResolvedJar>{};
  for (final jar in jars) {
    final key = '${jar.coordinate.groupId}:${jar.coordinate.artifactId}';
    final current = best[key];
    if (current == null ||
        compareMavenVersions(
              jar.coordinate.version,
              current.coordinate.version,
            ) >
            0) {
      best[key] = jar;
    }
  }
  return best.values.toList()
    ..sort((final a, final b) => a.jarPath.compareTo(b.jarPath));
}

/// Processes local AAR files declared in `pipeline.local_aars`.
///
/// Extracts classes.jar (for dexing), jni natives, and res into the build dir;
/// results land in [PipelineState.extraRuntimeJars], `aarNativeLibsByAbi`, and
/// `aarResDirs` for downstream compile/package steps.
class LocalAarsStep extends BuildStep {
  LocalAarsStep(this.aarPaths, {this.verbose = false});
  @override
  Set<Artifact<Object>> get provides => {aarNativeLibsByAbi, aarResDirs};

  final List<String> aarPaths;
  final bool verbose;

  @override
  String get name => 'local-aars';

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    // ADR-0010: constructor paths win; pipeline-level overrides fill in.
    final effective = aarPaths.isNotEmpty
        ? aarPaths
        : (state.pipelineOverrides?.localAars ?? const <String>[]);
    if (effective.isEmpty) return StepResult.success();
    print('📦 Processing ${effective.length} local AAR file(s)...');
    // Merge on top of Maven-AAR payloads from ExtraDepsStep — never clobber.
    final jars = <String>[...state.extraRuntimeJars];
    final natives = <String, List<String>>{...state.aarNativeLibsByAbi};
    final resDirs = <String>[...state.aarResDirs];

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
      payload.nativeLibsByAbi.forEach((final abi, final paths) {
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
  _LayoutOnlyStep(this.toolchain);
  @override
  Set<Artifact<Object>> get provides => {abis, apkPath};

  final ResolvedToolchain toolchain;

  @override
  String get name => 'layout-only';

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
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
  final ResolvedToolchain toolchain, {
  final bool verbose = false,
  final bool layoutOnly = false,
  final bool strictPlugins = true,
  final bool allowNetwork = true,
  final DependencyCache? dependencyCache,
  final PipelineOverrides overrides = const PipelineOverrides(),
}) async {
  final cache =
      dependencyCache ??
      DependencyCache(verbose: verbose, allowNetwork: allowNetwork);
  final assembler = FlutterAssembler(verbose: verbose);
  final discovery = PluginDiscovery(verbose: verbose);

  // Layout-only test path keeps the old shortcut semantics.
  if (layoutOnly) {
    return Pipeline([_LayoutOnlyStep(toolchain)], verbose: verbose);
  }

  return Pipeline([
    EnsureAndroidSdkStep(toolchain: toolchain),
    ResolveAbisStep(),
    PluginPackagingStep(
      toolchain: toolchain,
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
    FlutterAssembleStep(toolchain: toolchain, assembler: assembler),
    EngineExtractionStep(toolchain: toolchain),
    ReleaseAotStep(toolchain: toolchain, assembler: assembler),
    DependencyResolveStep(cache: cache),
    ExtraDepsStep(overrides.extraDeps, cache, verbose: verbose),
    LocalAarsStep(overrides.localAars, verbose: verbose),
    CompileAndDexStep(
      toolchain: toolchain,
      resourceConfigs: overrides.resourceConfigs,
    ),
    ExtraAssetsStep(overrides.extraAssets),
    PackageAndSignStep(toolchain: toolchain, signing: overrides.signing),
    ValidateLayoutStep(),
    RecordRunSessionStep(toolchain: toolchain),
    PostBuildLintStep(maxSizeMb: overrides.maxSizeMb),
  ], verbose: verbose);
}

/// Builds the default no-Gradle AAB pipeline (ADR-0004).
///
/// Shares steps 1–10 with the APK pipeline; diverges at resource linking
/// (`--proto-format`), packaging (`base/` module + jarsigner v1) and layout
/// validation.
Future<Pipeline> defaultAabPipeline(
  final ResolvedToolchain toolchain, {
  final bool verbose = false,
  final bool strictPlugins = true,
  final bool allowNetwork = true,
  final DependencyCache? dependencyCache,
  final PipelineOverrides overrides = const PipelineOverrides(),
}) async {
  final cache =
      dependencyCache ??
      DependencyCache(verbose: verbose, allowNetwork: allowNetwork);
  final assembler = FlutterAssembler(verbose: verbose);
  final discovery = PluginDiscovery(verbose: verbose);

  return Pipeline([
    EnsureAndroidSdkStep(toolchain: toolchain),
    ResolveAbisStep(),
    PluginPackagingStep(
      toolchain: toolchain,
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
    FlutterAssembleStep(toolchain: toolchain, assembler: assembler),
    EngineExtractionStep(toolchain: toolchain),
    ReleaseAotStep(toolchain: toolchain, assembler: assembler),
    DependencyResolveStep(cache: cache),
    ExtraDepsStep(overrides.extraDeps, cache, verbose: verbose),
    LocalAarsStep(overrides.localAars, verbose: verbose),
    CompileProtoAndDexStep(
      toolchain: toolchain,
      resourceConfigs: overrides.resourceConfigs,
    ),
    ExtraAssetsStep(overrides.extraAssets),
    PackageAndSignAabStep(toolchain: toolchain, signing: overrides.signing),
    ValidateAabLayoutStep(),
    RecordRunSessionStep(toolchain: toolchain),
    PostBuildLintStep(maxSizeMb: overrides.maxSizeMb),
  ], verbose: verbose);
}
