

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
      pluginResDirs: packaged?.resDirs ?? const [],
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
    final signed = await packageAndSign(
      ctx: ctx,
      sdkLocator: sdkLocator,
      dexFiles: state.dexFiles,
      flutterAssetsDir: state.flutterAssetsDir!,
      libflutterByAbi: state.libflutterByAbi,
      libappByAbi: state.libappByAbi,
      extraNativeByAbi: state.packagedPlugins?.nativeLibsByAbi ?? const {},
    );
    state.apkPath = signed;
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
