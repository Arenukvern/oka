import '../../build/aab_layout.dart';
import '../../build/apk_layout.dart';
import '../../build/sdk_locator.dart';
import '../../config/build_context.dart';
import '../pipeline.dart';
import '../toolchain.dart';

/// aapt2 compile/link + kotlinc/javac + d8 → dex files.
class CompileAndDexStep implements BuildStep {
  final SdkLocator sdkLocator;

  @override
  String get name => 'compile-and-dex';

  CompileAndDexStep(this.sdkLocator);

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    print('🔨 Compiling resources and Java/Kotlin (Android SDK tools)...');
    final packaged = state.packagedPlugins;
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
    );
    if (!result.ok) return StepResult.failure(result.error!);
    state.dexFiles = result.dexFiles;
    return StepResult.success();
  }
}

/// Stages the APK layout, zips, zipaligns and signs.
class PackageAndSignStep implements BuildStep {
  final SdkLocator sdkLocator;

  @override
  String get name => 'package-and-sign';

  PackageAndSignStep(this.sdkLocator);

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
    );
    state.apkPath = signed;
    return StepResult.success();
  }
}

/// aapt2 compile + proto-format link + javac/kotlinc + d8 (AAB, ADR-0004).
class CompileProtoAndDexStep implements BuildStep {
  final SdkLocator sdkLocator;

  @override
  String get name => 'compile-proto-and-dex';

  CompileProtoAndDexStep(this.sdkLocator);

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    print('🔨 Compiling resources (proto) and Java/Kotlin for AAB...');
    final packaged = state.packagedPlugins;
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
    );
    if (!result.ok) return StepResult.failure(result.error!);
    state.dexFiles = result.dexFiles;
    return StepResult.success();
  }
}

/// Stages the AAB `base/` module, zips and signs with jarsigner (v1).
class PackageAndSignAabStep implements BuildStep {
  final SdkLocator sdkLocator;

  @override
  String get name => 'package-and-sign-aab';

  PackageAndSignAabStep(this.sdkLocator);

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
      );
      state.apkPath = signed; // artifact path slot shared across pipelines
      return StepResult.success();
    } on Exception catch (e) {
      return StepResult.failure('aab packaging failed: $e');
    }
  }
}

/// Validates the produced AAB layout (proto manifest + dex + assets + libs).
class ValidateAabLayoutStep implements BuildStep {
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
class ValidateLayoutStep implements BuildStep {
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
