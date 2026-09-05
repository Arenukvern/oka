import 'dart:io';

import '../../android_artifacts.dart';
import '../../build/aab_layout.dart';
import '../../build/apk_layout.dart';
import '../../build/sdk_locator.dart';
import 'package:path/path.dart' as p;
import 'package:oka_core/src/config/build_context.dart';
import 'package:oka_core/src/pipeline/pipeline.dart';
import '../../android_state.dart';
import '../toolchain.dart';
import '../../auto_resolve.dart';
import '../../build_cache.dart';
import '../../signing_config.dart';

/// aapt2 compile/link + kotlinc/javac + d8 → dex files.
class CompileAndDexStep extends BuildStep {
  @override
  Set<Artifact<Object>> get requires => {hostDir, embeddingJar, packagedPlugins};

  @override
  Set<Artifact<Object>> get provides => {dexFiles};

  final SdkLocator sdkLocator;

  /// Resource qualifier filter (aapt2 `--configs`), e.g. `['en', 'ru']`.
  final List<String> resourceConfigs;

  @override
  String get name => 'compile-and-dex';

  CompileAndDexStep({SdkLocator? sdkLocator, this.resourceConfigs = const []})
    : sdkLocator = sdkLocator ?? SdkLocator();

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
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
        .map((p) => p.plugin.path)
        .expand(
          (path) => [
            '$path/android/build.gradle',
            '$path/android/build.gradle.kts',
          ],
        )
        .toList();
    final javaLevel = effectiveJavaLevel(
      configVersion: ctx.config.android.javaVersion,
      pluginGradleFiles: gradleFiles,
      onBump: (m) => ctx.warn(m),
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
      ...state.androidxJars.map((j) => j.jarPath),
      ...state.extraRuntimeJars,
    ], extras: [
      'abis:${state.abis.join(',')}',
      'compileSdk:${ctx.config.android.compileSdk}',
      'kotlin:${ctx.config.android.kotlinVersion}',
      'java:${ctx.config.android.javaVersion}',
      'resourceConfigs:${resourceConfigs.join(',')}',
      'versionCode:${version.versionCode}',
      'versionName:${version.versionName}',
      'java:$javaLevel',
    ]);
    final cached = cache.hit(
      'compile-and-dex',
      compileFp,
      validate: (o) => (o['dex_files'] as List?)?.cast<String>().every(
            (f) => File(f).existsSync(),
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
      sdkLocator: sdkLocator,
      hostDir: state.hostDir!,
      embeddingJar: state.embeddingJar!,
      androidxJarPaths: [
        ...state.androidxJars.map((j) => j.jarPath),
        ...state.extraRuntimeJars,
      ],
      pluginJavaSources: packaged?.allJavaSources ?? const [],
      pluginKotlinSources: packaged?.allKotlinSources ?? const [],
      pluginJarDeps: packaged?.allJarDeps ?? const [],
      pluginResDirs: [...state.aarResDirs, ...?packaged?.resDirs],
      resourceConfigs: resourceConfigs,
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
  @override
  Set<Artifact<Object>> get requires =>
      {dexFiles, flutterAssetsDir, libflutterByAbi};

  @override
  Set<Artifact<Object>> get provides => {apkPath};

  final SdkLocator sdkLocator;

  /// Release keystore configuration (null → auto-resolve → debug fallback).
  final SigningConfig? signing;

  @override
  String get name => 'package-and-sign';

  PackageAndSignStep({SdkLocator? sdkLocator, this.signing})
    : sdkLocator = sdkLocator ?? SdkLocator();

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    print('📱 Packaging APK...');
    // Merge AAR natives (Maven-resolved + local) into the plugin natives map.
    final extraNatives = <String, List<String>>{
      ...state.packagedPlugins?.nativeLibsByAbi ?? const {},
    };
    state.aarNativeLibsByAbi.forEach((abi, paths) {
      final norm = normalizeAbi(abi);
      extraNatives.putIfAbsent(norm, () => []).addAll(paths);
    });

    final signed = await packageAndSign(
      ctx: ctx,
      sdkLocator: sdkLocator,
      dexFiles: state.dexFiles,
      flutterAssetsDir: state.flutterAssetsDir!,
      libflutterByAbi: state.libflutterByAbi,
      libappByAbi: state.libappByAbi,
      extraNativeByAbi: extraNatives,
      signing: signing,
    );
    state.apkPath = signed;
    return StepResult.success();
  }
}

/// aapt2 compile + proto-format link + javac/kotlinc + d8 (AAB, ADR-0004).
class CompileProtoAndDexStep extends BuildStep {
  @override
  Set<Artifact<Object>> get requires => {hostDir, embeddingJar, packagedPlugins};

  @override
  Set<Artifact<Object>> get provides => {dexFiles};

  final SdkLocator sdkLocator;

  /// Resource qualifier filter (aapt2 `--configs`).
  final List<String> resourceConfigs;

  @override
  String get name => 'compile-proto-and-dex';

  CompileProtoAndDexStep({
    SdkLocator? sdkLocator,
    this.resourceConfigs = const [],
  }) : sdkLocator = sdkLocator ?? SdkLocator();

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
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
        .map((p) => p.plugin.path)
        .expand(
          (path) => [
            '$path/android/build.gradle',
            '$path/android/build.gradle.kts',
          ],
        )
        .toList();
    final javaLevel = effectiveJavaLevel(
      configVersion: ctx.config.android.javaVersion,
      pluginGradleFiles: gradleFiles,
      onBump: (m) => ctx.warn(m),
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
      ...state.androidxJars.map((j) => j.jarPath),
      ...state.extraRuntimeJars,
    ], extras: [
      'proto:true',
      'abis:${state.abis.join(',')}',
      'compileSdk:${ctx.config.android.compileSdk}',
      'kotlin:${ctx.config.android.kotlinVersion}',
      'java:${ctx.config.android.javaVersion}',
      'resourceConfigs:${resourceConfigs.join(',')}',
      'versionCode:${ctx.config.android.versionCode}',
      'versionName:${ctx.config.android.versionName}',
    ]);
    final cached = cache.hit(
      'compile-proto-and-dex',
      compileFp,
      validate: (o) => (o['dex_files'] as List?)?.cast<String>().every(
            (f) => File(f).existsSync(),
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
      sdkLocator: sdkLocator,
      hostDir: state.hostDir!,
      embeddingJar: state.embeddingJar!,
      androidxJarPaths: [
        ...state.androidxJars.map((j) => j.jarPath),
        ...state.extraRuntimeJars,
      ],
      pluginJavaSources: packaged?.allJavaSources ?? const [],
      pluginKotlinSources: packaged?.allKotlinSources ?? const [],
      pluginJarDeps: packaged?.allJarDeps ?? const [],
      pluginResDirs: [...state.aarResDirs, ...?packaged?.resDirs],
      resourceConfigs: resourceConfigs,
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
  @override
  Set<Artifact<Object>> get requires =>
      {dexFiles, flutterAssetsDir, libflutterByAbi};

  @override
  Set<Artifact<Object>> get provides => {apkPath};

  final SdkLocator sdkLocator;

  /// Release keystore configuration (null → auto-resolve → debug fallback).
  final SigningConfig? signing;

  @override
  String get name => 'package-and-sign-aab';

  PackageAndSignAabStep({SdkLocator? sdkLocator, this.signing})
    : sdkLocator = sdkLocator ?? SdkLocator();

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    print('📦 Packaging App Bundle...');
    final extraNatives = <String, List<String>>{
      ...state.packagedPlugins?.nativeLibsByAbi ?? const {},
    };
    state.aarNativeLibsByAbi.forEach((abi, paths) {
      final norm = normalizeBundleAbi(abi);
      extraNatives.putIfAbsent(norm, () => []).addAll(paths);
    });

    try {
      final signed = await packageAndSignAab(
        ctx: ctx,
        sdkLocator: sdkLocator,
        dexFiles: state.dexFiles,
        flutterAssetsDir: state.flutterAssetsDir!,
        libflutterByAbi: state.libflutterByAbi,
        libappByAbi: state.libappByAbi,
        extraNativeByAbi: extraNatives,
        signing: signing,
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
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
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

/// Validates the produced APK layout (dex + flutter_assets + lib/<abi>).
class ValidateLayoutStep extends BuildStep {
  @override
  Set<Artifact<Object>> get requires => {apkPath, abis};

  @override
  String get name => 'validate-layout';

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
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
