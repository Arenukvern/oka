import 'dart:io';
import 'package:oka_core/oka_core.dart';

import 'package:path/path.dart' as p;

import '../../android_artifacts.dart';
import '../../android_state.dart';
import '../../auto_resolve.dart';
import '../../build/aab_layout.dart';
import '../../build/apk_layout.dart';
import '../../build/toolchain.dart';
import '../../build_cache.dart';
import '../../signing_config.dart';
import '../toolchain.dart';

/// aapt2 compile/link + kotlinc/javac + d8 → dex files.
class CompileAndDexStep extends BuildStep {

  CompileAndDexStep({this.toolchain, this.resourceConfigs = const []});
  @override
  Set<Artifact<Object>> get requires => {hostDir, embeddingJar, packagedPlugins};

  @override
  Set<Artifact<Object>> get provides => {dexFiles};

  /// Null → [PipelineState.resolvedToolchain] → default (ADR-0013 T1).
  final ResolvedToolchain? toolchain;

  /// Resource qualifier filter (aapt2 `--configs`), e.g. `['en', 'ru']`.
  final List<String> resourceConfigs;

  /// ADR-0010: constructor value wins; pipeline-level overrides fill in.
  List<String> _effectiveResourceConfigs(final PipelineState state) =>
      resourceConfigs.isNotEmpty
          ? resourceConfigs
          : (state.pipelineOverrides?.resourceConfigs ?? const []);

  @override
  String get name => 'compile-and-dex';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    final packaged = state.packagedPlugins;
    // ADR-0007 auto-resolve: kotlinc self-install, java bump, version fallback.
    if ((packaged?.allKotlinSources ?? const []).isNotEmpty) {
      final kotlincOk = await ensureKotlinc(verbose: ctx.verbose);
      if (!kotlincOk) {
        return StepResult.failure(
          'Kotlin sources present but kotlinc unavailable and auto-install '
          'failed/disabled. Install: oka get kotlin',
        );
      }
    }
    final gradleFiles = (packaged?.plugins ?? const [])
        .map((final p) => p.plugin.path)
        .expand(
          (final path) => [
            '$path/android/build.gradle',
            '$path/android/build.gradle.kts',
          ],
        )
        .toList();
    final javaLevel = effectiveJavaLevel(
      configVersion: ctx.config.android.javaVersion,
      pluginGradleFiles: gradleFiles,
      onBump: ctx.warn,
    );
    final version = resolveAndroidVersion(
      ctx.projectPath,
      configVersionCode: ctx.config.android.versionCode,
      configVersionName: ctx.config.android.versionName,
    );
    final cache = StepCache(ctx.buildDir, verbose: ctx.verbose);
    await cache.load();
    final compileFp = await fingerprintInputs([
      ...filesUnder(state.hostDir ?? '/nonexistent'),
      ...filesUnder(p.join(ctx.buildDir, 'res')),
      if (File(p.join(ctx.buildDir, 'AndroidManifest.xml')).existsSync())
        p.join(ctx.buildDir, 'AndroidManifest.xml'),
      ...(packaged?.allJavaSources ?? const []),
      ...(packaged?.allKotlinSources ?? const []),
      ...(packaged?.resDirs ?? const []).expand(filesUnder),
      ...state.aarResDirs.expand(filesUnder),
      ...state.androidxJars.map((final j) => j.jarPath),
      ...state.extraRuntimeJars,
    ], extras: [
      'abis:${state.abis.join(',')}',
      'compileSdk:${ctx.config.android.compileSdk}',
      'kotlin:${ctx.config.android.kotlinVersion}',
      'java:${ctx.config.android.javaVersion}',
      'resourceConfigs:${_effectiveResourceConfigs(state).join(',')}',
      'versionCode:${version.versionCode}',
      'versionName:${version.versionName}',
      'java:$javaLevel',
    ]);
    final cached = cache.hit(
      'compile-and-dex',
      compileFp,
      validate: (final o) => (o['dex_files'] as List?)?.cast<String>().every(
            (final f) => File(f).existsSync(),
          ) ??
          false,
    );
    if (cached != null) {
      print('🔨 compile-and-dex: unchanged inputs — reusing dex');
      state.dexFiles = (cached['dex_files'] as List).cast<String>().toList();
      return StepResult.success();
    }
    print('🔨 Compiling resources and Java/Kotlin (Android SDK tools)...');
    final result = await compileAndDex(
      ctx: ctx,
      toolchain:
          toolchain ?? state.resolvedToolchain ?? ResolvedToolchain(),
      hostDir: state.hostDir!,
      embeddingJar: state.embeddingJar!,
      androidxJarPaths: [
        ...state.androidxJars.map((final j) => j.jarPath),
        ...state.extraRuntimeJars,
      ],
      pluginJavaSources: packaged?.allJavaSources ?? const [],
      pluginKotlinSources: packaged?.allKotlinSources ?? const [],
      pluginJarDeps: packaged?.allJarDeps ?? const [],
      pluginResDirs: [...state.aarResDirs, ...?packaged?.resDirs],
      resourceConfigs: _effectiveResourceConfigs(state),
      versionCode: version.versionCode.toString(),
      versionName: version.versionName,
      javaVersionOverride: javaLevel,
    );
    if (!result.ok) return StepResult.failure(result.error!);
    state.dexFiles = result.dexFiles;
    await cache.store('compile-and-dex', compileFp, {
      'dex_files': result.dexFiles,
    });
    return StepResult.success();
  }
}

/// Stages the APK layout, zips, zipaligns and signs.
class PackageAndSignStep extends BuildStep {

  PackageAndSignStep({this.toolchain, this.signing});
  @override
  Set<Artifact<Object>> get requires =>
      {dexFiles, flutterAssetsDir, libflutterByAbi};

  @override
  Set<Artifact<Object>> get provides => {apkPath};

  /// Null → [PipelineState.resolvedToolchain] → default (ADR-0013 T1).
  final ResolvedToolchain? toolchain;

  /// Release keystore configuration (null → auto-resolve → debug fallback).
  final SigningConfig? signing;

  @override
  String get name => 'package-and-sign';

  /// ADR-0010: constructor signing wins; pipeline-level overrides fill in.
  SigningConfig? _effectiveSigning(final PipelineState state) =>
      signing ?? state.pipelineOverrides?.signing;

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    print('📱 Packaging APK...');
    // Merge AAR natives (Maven-resolved + local) into the plugin natives map.
    final extraNatives = <String, List<String>>{
      ...state.packagedPlugins?.nativeLibsByAbi ?? const {},
    };
    state.aarNativeLibsByAbi.forEach((final abi, final paths) {
      final norm = normalizeAbi(abi);
      extraNatives.putIfAbsent(norm, () => []).addAll(paths);
    });

    final signed = await packageAndSign(
      ctx: ctx,
      toolchain:
          toolchain ?? state.resolvedToolchain ?? ResolvedToolchain(),
      dexFiles: state.dexFiles,
      flutterAssetsDir: state.flutterAssetsDir!,
      libflutterByAbi: state.libflutterByAbi,
      libappByAbi: state.libappByAbi,
      extraNativeByAbi: extraNatives,
      signing: _effectiveSigning(state),
    );
    state.apkPath = signed;
    return StepResult.success();
  }
}

/// aapt2 compile + proto-format link + javac/kotlinc + d8 (AAB, ADR-0004).
class CompileProtoAndDexStep extends BuildStep {

  CompileProtoAndDexStep({this.toolchain, this.resourceConfigs = const []});
  @override
  Set<Artifact<Object>> get requires => {hostDir, embeddingJar, packagedPlugins};

  @override
  Set<Artifact<Object>> get provides => {dexFiles};

  /// Null → [PipelineState.resolvedToolchain] → default (ADR-0013 T1).
  final ResolvedToolchain? toolchain;

  /// Resource qualifier filter (aapt2 `--configs`).
  final List<String> resourceConfigs;

  @override
  String get name => 'compile-proto-and-dex';

  /// ADR-0010: constructor value wins; pipeline-level overrides fill in.
  List<String> _effectiveResourceConfigs(final PipelineState state) =>
      resourceConfigs.isNotEmpty
          ? resourceConfigs
          : (state.pipelineOverrides?.resourceConfigs ?? const []);

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    final packaged = state.packagedPlugins;
    // ADR-0007 auto-resolve: kotlinc self-install, java bump, version fallback.
    if ((packaged?.allKotlinSources ?? const []).isNotEmpty) {
      final kotlincOk = await ensureKotlinc(verbose: ctx.verbose);
      if (!kotlincOk) {
        return StepResult.failure(
          'Kotlin sources present but kotlinc unavailable and auto-install '
          'failed/disabled. Install: oka get kotlin',
        );
      }
    }
    final gradleFiles = (packaged?.plugins ?? const [])
        .map((final p) => p.plugin.path)
        .expand(
          (final path) => [
            '$path/android/build.gradle',
            '$path/android/build.gradle.kts',
          ],
        )
        .toList();
    final javaLevel = effectiveJavaLevel(
      configVersion: ctx.config.android.javaVersion,
      pluginGradleFiles: gradleFiles,
      onBump: ctx.warn,
    );
    final version = resolveAndroidVersion(
      ctx.projectPath,
      configVersionCode: ctx.config.android.versionCode,
      configVersionName: ctx.config.android.versionName,
    );
    final cache = StepCache(ctx.buildDir, verbose: ctx.verbose);
    await cache.load();
    final compileFp = await fingerprintInputs([
      ...filesUnder(state.hostDir ?? '/nonexistent'),
      ...filesUnder(p.join(ctx.buildDir, 'res')),
      if (File(p.join(ctx.buildDir, 'AndroidManifest.xml')).existsSync())
        p.join(ctx.buildDir, 'AndroidManifest.xml'),
      ...(packaged?.allJavaSources ?? const []),
      ...(packaged?.allKotlinSources ?? const []),
      ...(packaged?.resDirs ?? const []).expand(filesUnder),
      ...state.aarResDirs.expand(filesUnder),
      ...state.androidxJars.map((final j) => j.jarPath),
      ...state.extraRuntimeJars,
    ], extras: [
      'proto:true',
      'abis:${state.abis.join(',')}',
      'compileSdk:${ctx.config.android.compileSdk}',
      'kotlin:${ctx.config.android.kotlinVersion}',
      'java:${ctx.config.android.javaVersion}',
      'resourceConfigs:${_effectiveResourceConfigs(state).join(',')}',
      'versionCode:${ctx.config.android.versionCode}',
      'versionName:${ctx.config.android.versionName}',
    ]);
    final cached = cache.hit(
      'compile-proto-and-dex',
      compileFp,
      validate: (final o) => (o['dex_files'] as List?)?.cast<String>().every(
            (final f) => File(f).existsSync(),
          ) ??
          false,
    );
    if (cached != null) {
      print('🔨 compile-proto-and-dex: unchanged inputs — reusing dex');
      state.dexFiles =
          (cached['dex_files'] as List).cast<String>().toList();
      return StepResult.success();
    }
    print('🔨 Compiling resources (proto) and Java/Kotlin for AAB...');
    final result = await compileAndDexProto(
      ctx: ctx,
      toolchain:
          toolchain ?? state.resolvedToolchain ?? ResolvedToolchain(),
      hostDir: state.hostDir!,
      embeddingJar: state.embeddingJar!,
      androidxJarPaths: [
        ...state.androidxJars.map((final j) => j.jarPath),
        ...state.extraRuntimeJars,
      ],
      pluginJavaSources: packaged?.allJavaSources ?? const [],
      pluginKotlinSources: packaged?.allKotlinSources ?? const [],
      pluginJarDeps: packaged?.allJarDeps ?? const [],
      pluginResDirs: [...state.aarResDirs, ...?packaged?.resDirs],
      resourceConfigs: _effectiveResourceConfigs(state),
      versionCode: version.versionCode.toString(),
      versionName: version.versionName,
      javaVersionOverride: javaLevel,
    );
    if (!result.ok) return StepResult.failure(result.error!);
    state.dexFiles = result.dexFiles;
    await cache.store('compile-proto-and-dex', compileFp, {
      'dex_files': result.dexFiles,
    });
    return StepResult.success();
  }
}

/// Stages the AAB `base/` module, zips and signs with jarsigner (v1).
class PackageAndSignAabStep extends BuildStep {

  PackageAndSignAabStep({this.toolchain, this.signing});
  @override
  Set<Artifact<Object>> get requires =>
      {dexFiles, flutterAssetsDir, libflutterByAbi};

  @override
  Set<Artifact<Object>> get provides => {apkPath};

  /// Null → [PipelineState.resolvedToolchain] → default (ADR-0013 T1).
  final ResolvedToolchain? toolchain;

  /// Release keystore configuration (null → auto-resolve → debug fallback).
  final SigningConfig? signing;

  @override
  String get name => 'package-and-sign-aab';

  /// ADR-0010: constructor signing wins; pipeline-level overrides fill in.
  SigningConfig? _effectiveSigningAab(final PipelineState state) =>
      signing ?? state.pipelineOverrides?.signing;

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    print('📦 Packaging App Bundle...');
    final extraNatives = <String, List<String>>{
      ...state.packagedPlugins?.nativeLibsByAbi ?? const {},
    };
    state.aarNativeLibsByAbi.forEach((final abi, final paths) {
      final norm = normalizeBundleAbi(abi);
      extraNatives.putIfAbsent(norm, () => []).addAll(paths);
    });

    try {
      final signed = await packageAndSignAab(
        ctx: ctx,
        toolchain:
            toolchain ?? state.resolvedToolchain ?? ResolvedToolchain(),
        dexFiles: state.dexFiles,
        flutterAssetsDir: state.flutterAssetsDir!,
        libflutterByAbi: state.libflutterByAbi,
        libappByAbi: state.libappByAbi,
        extraNativeByAbi: extraNatives,
        signing: _effectiveSigningAab(state),
      );
      state.apkPath = signed; // artifact path slot shared across pipelines
      return StepResult.success();
    } on Exception catch (e) {
      return StepResult.failure('aab packaging failed: $e');
    }
  }
}

/// Validates the produced AAB layout (proto manifest + dex + assets + libs).
class ValidateAabLayoutStep extends BuildStep {
  @override
  Set<Artifact<Object>> get requires => {apkPath, abis};

  @override
  String get name => 'validate-aab-layout';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    final entries = await listAabEntries(state.apkPath!);
    final validation = validateAabPathSet(
      entries,
      spec: AabLayoutSpec(abis: state.abis, requireLibapp: ctx.mode.isRelease),
    );
    if (!validation.ok) {
      return StepResult.failure(
        'AAB layout incomplete after packaging. '
        'Missing: ${validation.missing.join(', ')}. '
        'Present: ${validation.present.join(', ')}',
      );
    }
    return StepResult.success();
  }
}

/// Validates the produced APK layout (dex + `flutter_assets` + `lib/<abi>`).
class ValidateLayoutStep extends BuildStep {
  @override
  Set<Artifact<Object>> get requires => {apkPath, abis};

  @override
  String get name => 'validate-layout';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    final entries = await listApkEntries(state.apkPath!);
    final validation = validatePathSet(
      entries,
      spec: ApkLayoutSpec(abis: state.abis, requireLibapp: ctx.mode.isRelease),
    );
    if (!validation.ok) {
      return StepResult.failure(
        'APK layout incomplete after packaging. '
        'Missing: ${validation.missing.join(', ')}. '
        'Present: ${validation.present.join(', ')}',
      );
    }
    return StepResult.success();
  }
}
