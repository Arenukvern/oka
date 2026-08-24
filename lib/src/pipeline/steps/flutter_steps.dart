import 'dart:io';

import 'package:path/path.dart' as p;

import '../../build/apk_layout.dart';
import '../../build/dependency_cache.dart';
import '../../build/flutter_assemble.dart';
import '../../build/sdk_locator.dart';
import '../../config/build_context.dart';
import '../pipeline.dart';

/// Runs `flutter assemble` to produce flutter_assets.
class FlutterAssembleStep implements BuildStep {
  final SdkLocator sdkLocator;
  final FlutterAssembler assembler;

  @override
  String get name => 'flutter-assemble';

  FlutterAssembleStep({required this.sdkLocator, required this.assembler});

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    print('🎨 Running flutter assemble...');
    final assembleOut = p.join(ctx.buildDir, 'assemble');
    final entrypoint = ctx.config.flutter.entrypoint.isEmpty
        ? 'lib/main.dart'
        : ctx.config.flutter.entrypoint;
    final assembleResult = await assembler.assembleApplication(
      projectPath: ctx.projectPath,
      outputDir: assembleOut,
      entrypoint: entrypoint,
      mode: ctx.mode,
      primaryAbi: state.abis.first,
      extraArgs: ctx.config.flutter.buildArgs,
    );
    if (!assembleResult.success) {
      return StepResult.failure(
        'flutter assemble failed (exit ${assembleResult.exitCode}):\n'
        '${assembleResult.stderr}\n${assembleResult.stdout}',
      );
    }
    final assetsDir =
        assembleResult.flutterAssetsDir ??
        await findFlutterAssetsDir(assembleOut);
    if (assetsDir == null) {
      return StepResult.failure(
        'flutter_assets not found under assemble output: $assembleOut',
      );
    }
    state.flutterAssetsDir = assetsDir;
    return StepResult.success();
  }
}

/// Extracts libflutter.so per ABI from the Flutter engine artifacts.
class EngineExtractionStep implements BuildStep {
  final SdkLocator sdkLocator;

  @override
  String get name => 'engine-extraction';

  EngineExtractionStep(this.sdkLocator);

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    print('📦 Extracting Flutter engine natives...');
    final engine = await engineArtifacts(ctx, sdkLocator);
    final libDir = p.join(ctx.buildDir, 'lib');
    final libflutterByAbi = await engine.extractLibflutterForAbis(
      abis: state.abis,
      libDir: libDir,
      release: ctx.mode.isRelease || ctx.mode.isProfile,
    );
    state.libflutterByAbi = libflutterByAbi;

    // Flutter embedding jar (classes only for javac/d8).
    final embeddingJarFull = await engine.findFlutterJar(
      state.abis.first,
      release: ctx.mode.isRelease,
    );
    if (embeddingJarFull == null) {
      return StepResult.failure(
        'flutter.jar (embedding) not found; run flutter precache',
      );
    }
    state.embeddingJar = await engine.extractEmbeddingClassesJar(
      flutterJar: embeddingJarFull,
      destJarPath: p.join(ctx.buildDir, 'flutter_embedding_classes.jar'),
    );
    return StepResult.success();
  }
}

/// Assembles release AOT (libapp.so) per ABI. No-op in debug/profile.
class ReleaseAotStep implements BuildStep {
  final SdkLocator sdkLocator;
  final FlutterAssembler assembler;

  @override
  String get name => 'release-aot';

  ReleaseAotStep({required this.sdkLocator, required this.assembler});

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    if (!ctx.mode.isRelease) return StepResult.success();

    print('⚡ Assembling release AOT (libapp.so)...');
    final entrypoint = ctx.config.flutter.entrypoint.isEmpty
        ? 'lib/main.dart'
        : ctx.config.flutter.entrypoint;
    final libappByAbi = <String, String>{};
    for (final abi in state.abis) {
      final aotOut = p.join(ctx.buildDir, 'aot', normalizeAbi(abi));
      final aotResult = await assembler.assembleAot(
        projectPath: ctx.projectPath,
        outputDir: aotOut,
        entrypoint: entrypoint,
        abi: abi,
        extraArgs: ctx.config.flutter.buildArgs,
      );
      if (!aotResult.success) {
        return StepResult.failure(
          'flutter AOT assemble failed for $abi: ${aotResult.stderr}',
        );
      }
      final so = await findLibappSo(aotOut);
      if (so == null) {
        return StepResult.failure(
          'libapp.so/app.so not found for ABI $abi in $aotOut',
        );
      }
      final dest = p.join(ctx.buildDir, 'lib', normalizeAbi(abi), 'libapp.so');
      await File(dest).parent.create(recursive: true);
      await File(so).copy(dest);
      libappByAbi[normalizeAbi(abi)] = dest;
    }
    state.libappByAbi = libappByAbi;
    return StepResult.success();
  }
}

/// Resolves the AndroidX runtime dependency set (extensible via
/// `pipeline.extra_deps` in oka.yaml and [PipelineState.extraRuntimeJars]).
class DependencyResolveStep implements BuildStep {
  final DependencyCache cache;

  @override
  String get name => 'dependency-resolve';

  DependencyResolveStep(this.cache);

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    print('📚 Resolving AndroidX dependencies...');
    List<ResolvedJar> jars;
    try {
      jars = await cache.resolveFlutterAndroidX();
    } on Exception catch (e) {
      // Best-effort: compile may still succeed with cached JARs.
      print('⚠️  AndroidX resolve incomplete: $e');
      print('   Compile may fail without cached JARs under ~/.oka/cache/maven');
      jars = [];
    }

    // Merge plugin natives into lib/ while we hold plugin outputs.
    final packaged = state.packagedPlugins;
    if (packaged != null) {
      final libDir = p.join(ctx.buildDir, 'lib');
      for (final entry in packaged.nativeLibsByAbi.entries) {
        final abi = normalizeAbi(entry.key);
        for (final so in entry.value) {
          final dest = p.join(libDir, abi, p.basename(so));
          await File(dest).parent.create(recursive: true);
          await File(so).copy(dest);
          if (ctx.verbose) print('   packaged native: $dest');
        }
      }
    }

    state.androidxJars = jars;
    return StepResult.success();
  }
}
