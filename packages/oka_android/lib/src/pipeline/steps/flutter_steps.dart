import 'dart:io';

import 'package:path/path.dart' as p;

import '../../android_artifacts.dart';
import '../../build/apk_layout.dart';
import '../../build_cache.dart';
import '../../build/dependency_cache.dart';
import '../../build/flutter_assemble.dart';
import '../../build/sdk_locator.dart';
import 'package:oka_core/src/config/build_context.dart';
import 'package:oka_core/src/pipeline/pipeline.dart';
import '../../android_state.dart';

/// Runs `flutter assemble` to produce flutter_assets.
class FlutterAssembleStep extends BuildStep {
  @override
  Set<Artifact<Object>> get requires => {abis};

  @override
  Set<Artifact<Object>> get provides => {flutterAssetsDir};

  final SdkLocator sdkLocator;
  final FlutterAssembler assembler;

  /// Absolute paths of pubspec.yaml files for path: dependencies declared in
  /// the package config (sibling checkouts). Non-existent entries ignored.
  /// Resolves the Android SDK without failing the step — when unavailable,
  /// the flutter tool reports its own actionable error.
  Future<String?> _locateAndroidSdkSafe() async {
    try {
      return await sdkLocator.findAndroidSdk();
    } on Exception {
      return null;
    }
  }

  static List<File> _pathDependencyPubspecs(String packageConfigJson) {
    final out = <File>[];
    final rootUriRe = RegExp(r'"rootUri":\s*"([^"]+)"');
    for (final m in rootUriRe.allMatches(packageConfigJson)) {
      final uri = m.group(1)!;
      if (!uri.startsWith('file://')) continue;
      final root = Uri.parse(uri).toFilePath();
      final pubspec = File('$root/pubspec.yaml');
      if (pubspec.existsSync()) out.add(pubspec);
    }
    return out;
  }

  @override
  String get name => 'flutter-assemble';

  FlutterAssembleStep({SdkLocator? sdkLocator, FlutterAssembler? assembler})
    : sdkLocator = sdkLocator ?? SdkLocator(),
      assembler = assembler ?? FlutterAssembler();

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    final cache = StepCache(ctx.buildDir, verbose: ctx.verbose);
    await cache.load();
    final fp = await fingerprintInputs([
      ...filesUnder(p.join(ctx.projectPath, 'lib'), extension: '.dart'),
      ...filesUnder(p.join(ctx.projectPath, 'packages'), extension: '.dart'),
      if (File('${ctx.projectPath}/pubspec.yaml').existsSync())
        '${ctx.projectPath}/pubspec.yaml',
      if (File('${ctx.projectPath}/pubspec.lock').existsSync())
        '${ctx.projectPath}/pubspec.lock',
      if (File('${ctx.projectPath}/.dart_tool/package_config.json')
          .existsSync())
        '${ctx.projectPath}/.dart_tool/package_config.json',
    ], extras: [
      'entrypoint:${ctx.entrypoint}',
      'mode:${ctx.mode.name}',
      'abis:${state.abis.join(',')}',
      'defines:${(ctx.dartDefines.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join(',')}',
      'buildArgs:${ctx.config.flutter.buildArgs.join(',')}',
    ]);
    final cached = cache.hit('flutter-assemble', fp);
    if (cached != null) {
      print('🎨 flutter assemble: unchanged inputs — reusing artifacts');
      state.flutterAssetsDir = cached['flutter_assets_dir'] as String;
      return StepResult.success();
    }

    // Freshness check: `flutter assemble` (unlike `flutter build`) never runs
    // pub get implicitly; a stale package_config desynchronizes the kernel
    // compile from pubspec. Re-sync when pubspec is newer than the config.
    final packageConfig = File(
      p.join(ctx.projectPath, '.dart_tool', 'package_config.json'),
    );
    final pubspec = File(p.join(ctx.projectPath, 'pubspec.yaml'));
    // Staleness = own pubspec OR any path-dependency's pubspec newer than the
    // generated package_config (sibling checkouts change without touching
    // this project — bare `flutter assemble` never re-syncs on its own).
    final pathDepPubspecs = _pathDependencyPubspecs(
      packageConfig.existsSync() ? packageConfig.readAsStringSync() : '',
    );
    final configTime = packageConfig.existsSync()
        ? packageConfig.lastModifiedSync()
        : DateTime.fromMillisecondsSinceEpoch(0);
    final stale = !packageConfig.existsSync() ||
        (pubspec.existsSync() &&
            pubspec.lastModifiedSync().isAfter(configTime)) ||
        pathDepPubspecs.any(
          (f) => f.existsSync() && f.lastModifiedSync().isAfter(configTime),
        );
    if (stale) {
      print('📦 package_config stale — running flutter pub get...');
      final pubGet = await Process.run(
        'flutter',
        const ['pub', 'get'],
        workingDirectory: ctx.projectPath,
      );
      if (pubGet.exitCode != 0) {
        return StepResult.failure(
          'flutter pub get failed:\n${pubGet.stderr}',
        );
      }
    }

    print('🎨 Running flutter assemble...');
    // ADR-0007 AUTO: the flutter tool subprocess resolves the Android SDK on
    // its own (env → project android/local.properties). Projects with a
    // stale/missing sdk.dir fail build_hooks even though oka found the SDK —
    // pass the located SDK through the environment so `flutter assemble` sees
    // exactly what oka's own steps see.
    final androidSdkHome = await _locateAndroidSdkSafe();
    final sdkEnv = androidSdkHome == null
        ? null
        : {'ANDROID_SDK_ROOT': androidSdkHome, 'ANDROID_HOME': androidSdkHome};
    final assembleOut = p.join(ctx.buildDir, 'assemble');
    final assembleResult = await assembler.assembleApplication(
      projectPath: ctx.projectPath,
      outputDir: assembleOut,
      entrypoint: ctx.entrypoint,
      mode: ctx.mode,
      primaryAbi: state.abis.first,
      extraArgs: ctx.config.flutter.buildArgs,
      dartDefines: ctx.dartDefines,
      environment: sdkEnv,
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
    await cache.store('flutter-assemble', fp, {
      'flutter_assets_dir': assetsDir,
    });
    return StepResult.success();
  }
}

/// Extracts libflutter.so per ABI from the Flutter engine artifacts.
class EngineExtractionStep extends BuildStep {
  @override
  Set<Artifact<Object>> get requires => {abis};

  @override
  Set<Artifact<Object>> get provides => {libflutterByAbi, embeddingJar};

  final SdkLocator sdkLocator;

  @override
  String get name => 'engine-extraction';

  EngineExtractionStep({SdkLocator? sdkLocator})
    : sdkLocator = sdkLocator ?? SdkLocator();

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
class ReleaseAotStep extends BuildStep {
    /// Resolves the Android SDK without failing the step.
  Future<String?> _locateAndroidSdkSafe() async {
    try {
      return await sdkLocator.findAndroidSdk();
    } on Exception {
      return null;
    }
  }

@override
  Set<Artifact<Object>> get requires => {abis};

  @override
  Set<Artifact<Object>> get provides => {libappByAbi};

  final SdkLocator sdkLocator;
  final FlutterAssembler assembler;

  @override
  String get name => 'release-aot';

  ReleaseAotStep({SdkLocator? sdkLocator, FlutterAssembler? assembler})
    : sdkLocator = sdkLocator ?? SdkLocator(),
      assembler = assembler ?? FlutterAssembler();

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    if (!ctx.mode.isRelease) return StepResult.success();

    final cache = StepCache(ctx.buildDir, verbose: ctx.verbose);
    await cache.load();
    final aotFp = await fingerprintInputs([
      ...filesUnder(p.join(ctx.projectPath, 'lib'), extension: '.dart'),
      ...filesUnder(p.join(ctx.projectPath, 'packages'), extension: '.dart'),
      if (File('${ctx.projectPath}/pubspec.lock').existsSync())
        '${ctx.projectPath}/pubspec.lock',
      if (File('${ctx.projectPath}/.dart_tool/package_config.json')
          .existsSync())
        '${ctx.projectPath}/.dart_tool/package_config.json',
    ], extras: [
      'entrypoint:${ctx.entrypoint}',
      'abis:${state.abis.join(',')}',
      'defines:${(ctx.dartDefines.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join(',')}',
    ]);
    final cachedAot = cache.hit('release-aot', aotFp);
    if (cachedAot != null) {
      print('⚡ release AOT: unchanged inputs — reusing libapp.so');
      state.libappByAbi =
          (cachedAot['libapp_by_abi'] as Map).cast<String, String>();
      return StepResult.success();
    }

    print('⚡ Assembling release AOT (libapp.so)...');
    final libappByAbi = <String, String>{};
    for (final abi in state.abis) {
      final aotOut = p.join(ctx.buildDir, 'aot', normalizeAbi(abi));
      final aotSdkEnv = await _locateAndroidSdkSafe();
      final aotResult = await assembler.assembleAot(
        projectPath: ctx.projectPath,
        outputDir: aotOut,
        entrypoint: ctx.entrypoint,
        abi: abi,
        extraArgs: ctx.config.flutter.buildArgs,
        dartDefines: ctx.dartDefines,
            environment: aotSdkEnv == null
          ? null
          : {
              'ANDROID_SDK_ROOT': aotSdkEnv,
              'ANDROID_HOME': aotSdkEnv,
            },
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
    await cache.store('release-aot', aotFp, {
      'libapp_by_abi': libappByAbi,
    });
    return StepResult.success();
  }
}

/// Resolves the AndroidX runtime dependency set (extensible via
/// `pipeline.extra_deps` in oka.yaml and [PipelineState.extraRuntimeJars]).
class DependencyResolveStep extends BuildStep {
  @override
  Set<Artifact<Object>> get provides => {androidxJars};

  final DependencyCache cache;

  @override
  String get name => 'dependency-resolve';

  DependencyResolveStep({DependencyCache? cache})
    : cache = cache ?? DependencyCache();

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
