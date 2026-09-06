import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import 'android_state.dart';
import 'build/bundletool.dart';
import 'build/dependency_cache.dart';
import 'build/launcher_icon.dart';
import 'build/sdk_locator.dart';
import 'manifest_spec.dart';
import 'pipeline/default_pipeline.dart';
import 'pipeline/steps/asset_steps.dart';
import 'pipeline/steps/flutter_steps.dart';
import 'pipeline/steps/host_steps.dart';
import 'pipeline/steps/tool_steps.dart';
import 'pipeline/toolchain.dart';
import 'post_build_lint.dart';
import 'signing_config.dart';
/// Declarative Android platform pipeline (ADR-0006).
///
/// Immutable configuration value: [overrides] (typed, [copyWith]-able) plus an
/// optional step list. When [steps] is null the default no-Gradle pipeline is
/// composed (APK or AAB depending on [BuildContext.buildAab]).
///
/// ## Minimal entrypoint
///
/// ```dart
/// Future<void> main(List<String> args) => okaRun(
///       args,
///       oka: const Oka(
///         pipelines: [
///           AndroidPipeline(
///             config: AndroidBuild(packageName: 'dev.example.app'),
///           ),
///         ],
///       ),
///     );
/// ```
///
/// ## Typed fast-settings + custom steps
///
/// ```dart
/// AndroidPipeline(
///   overrides: const PipelineOverrides(
///     extraDeps: ['androidx.core:core-ktx:1.13.1'],
///     resourceConfigs: ['en', 'ru'],
///   ),
///   steps: [...AndroidPipeline.defaultSteps, MyStep()],
/// )
/// ```
///
/// The artifact chain ([BuildStep.requires] / [BuildStep.provides]) is
/// re-validated whenever the step list changes, so a mis-ordered list fails
/// at composition time — before any tool runs.
///
/// See also:
///
/// * [defaultSteps], the default no-Gradle step sequence.
/// * [PipelineOverrides], packaging fast-settings (deps, icon, signing...).
/// * [AndroidBuild] / [FlutterBuild], typed base config (ADR-0010).
class AndroidPipeline implements PlatformPipeline {
  const AndroidPipeline({
    this.overrides = const PipelineOverrides(),
    this.steps,
    this.strictPlugins = true,
    this.config,
    this.flutterConfig,
  });

  /// Typed fast-settings (deps, assets, deeplinks, icon, manifest, signing).
  final PipelineOverrides overrides;

  /// Full step list. Null → [defaultSteps] (behavior-preserving default).
  final List<BuildStep>? steps;

  /// Whether unsupported plugins abort the build (strict) or warn (soft).
  /// Soft mode (`false`) is the `--soft-plugins` escape hatch for builds that
  /// can tolerate an empty plugin registrant.
  final bool strictPlugins;

  /// Typed base config (ADR-0010): the `android:` section, strictly typed.
  /// Deep-merged over oka.yaml by `okaRun`; steps keep reading `ctx.config`.
  final AndroidBuild? config;

  /// Typed Flutter build settings (ADR-0010): the `flutter:` section.
  final FlutterBuild? flutterConfig;

  @override
  String get platform => 'android';

  @override
  Map<String, dynamic> get configOverrides => {
    // Project display name lives at doc level (was top-level `name:` in
    // oka.yaml) — feeds the app_name resource + label fallback.
    if (config != null && config!.name.isNotEmpty) 'name': config!.name,
    if (config != null) 'android': config!.toConfigMap(),
    if (flutterConfig != null) 'flutter': flutterConfig!.toConfigMap(),
  };

  AndroidPipeline copyWith({
    final PipelineOverrides? overrides,
    final List<BuildStep>? steps,
    final bool? strictPlugins,
    final AndroidBuild? config,
    final FlutterBuild? flutterConfig,
  }) => AndroidPipeline(
    overrides: overrides ?? this.overrides,
    steps: steps ?? this.steps,
    strictPlugins: strictPlugins ?? this.strictPlugins,
    config: config ?? this.config,
    flutterConfig: flutterConfig ?? this.flutterConfig,
  );

  /// The default no-Gradle step sequence (fresh instances; services resolve
  /// lazily). Covers: SDK/tool validation, `flutter assemble`, host codegen
  /// (`MainActivity` + plugin registrant), plugin packaging, resource and DEX
  /// compilation, APK/AAB layout staging, and signing.
  ///
  /// Treat it as a starting list — append custom steps, or replace
  /// individual entries to specialize (each step is a plain value).
  static List<BuildStep> get defaultSteps {
    final sdkLocator = SdkLocator();
    final cache = DependencyCache();
    return [
      EnsureAndroidSdkStep(sdkLocator: sdkLocator),
      ResolveAbisStep(),
      PluginPackagingStep(sdkLocator: sdkLocator, dependencyCache: cache),
      HostCodegenStep(),
      FlutterAssembleStep(sdkLocator: sdkLocator),
      EngineExtractionStep(sdkLocator: sdkLocator),
      ReleaseAotStep(sdkLocator: sdkLocator),
      DependencyResolveStep(cache: cache),
      // Fast-settings surfaces (ADR-0010): steps read pipeline-level
      // overrides seeded into the runtime scope; constructor args stay empty.
      ExtraDepsStep(const [], cache),
      LocalAarsStep(const []),
      CompileAndDexStep(sdkLocator: sdkLocator),
      ExtraAssetsStep(const []),
      PackageAndSignStep(sdkLocator: sdkLocator),
      ValidateLayoutStep(),
      PostBuildLintStep(),
    ];
  }

  @override
  Future<StepResult> run(final BuildContext ctx) async {
    if (steps != null && ctx.buildAab) {
      // Explicit step lists own APK-vs-AAB packaging — `--aab` only names the
      // build dir unless the composed list swaps in the AAB tail
      // (CompileProtoAndDexStep → PackageAndSignAabStep → ValidateAabLayoutStep).
      print(
        '⚠️  Explicit step list + --aab: the composed steps control the '
        'artifact type. Ensure the list uses the AAB packaging tail, '
        'otherwise this build produces an APK.',
      );
    }
    // Merge yaml fast-settings with Dart-composed overrides (Dart wins).
    final yaml = await PipelineOverrides.load(ctx.projectPath);
    final signing =
        overrides.signing ??
        yaml.signing ??
        await SigningConfig.fromKeyProperties(ctx.projectPath);
    final merged = yaml.copyWith(
      extraDeps: overrides.extraDeps.isEmpty ? null : overrides.extraDeps,
      extraAssets: overrides.extraAssets.isEmpty ? null : overrides.extraAssets,
      deeplinks: overrides.deeplinks.isEmpty ? null : overrides.deeplinks,
      resourceConfigs: overrides.resourceConfigs.isEmpty
          ? null
          : overrides.resourceConfigs,
      manifest: overrides.manifest,
      signing: signing,
      icon: overrides.icon == const IconConfig() ? null : overrides.icon,
      localAars: overrides.localAars.isEmpty ? null : overrides.localAars,
      resDirs: overrides.resDirs.isEmpty ? null : overrides.resDirs,
      excludePlugins: overrides.excludePlugins.isEmpty
          ? null
          : overrides.excludePlugins,
      maxSizeMb: overrides.maxSizeMb,
    );

    final Pipeline pipeline;
    if (steps != null) {
      pipeline = Pipeline(steps!, verbose: ctx.verbose);
    } else if (ctx.buildAab) {
      pipeline = await defaultAabPipeline(
        SdkLocator(),
        verbose: ctx.verbose,
        strictPlugins: strictPlugins,
        overrides: merged,
      );
    } else {
      pipeline = await defaultApkPipeline(
        SdkLocator(),
        verbose: ctx.verbose,
        strictPlugins: strictPlugins,
        overrides: merged,
      );
    }
    // ADR-0010: seed the merged overrides into the runtime scope so hooks
    // composing explicit step lists (`steps: [...AndroidPipeline.defaultSteps]`)
    // get fast-settings applied without threading every constructor. Steps
    // prefer their explicit constructor values and fall back to this.
    final state = PipelineState()..pipelineOverrides = merged;
    final result = await pipeline.run(ctx, initialState: state);
    if (!result.ok) return result;
    final artifactPath = result.data['apk_path'];
    if (ctx.buildAab &&
        ctx.verifyAab &&
        artifactPath is String &&
        artifactPath.endsWith('.aab')) {
      final ok = await _verifyAabWithBundletool(ctx, artifactPath);
      if (!ok) {
        return StepResult.failure('AAB verification failed (bundletool)');
      }
    }
    return result;
  }

  /// bundletool verification for produced AABs (ADR-0004): runs
  /// `build-apks --mode=universal` — the same parsing path as Play — and
  /// extracts the installable universal APK.
  Future<bool> _verifyAabWithBundletool(
    final BuildContext ctx,
    final String aabPath,
  ) async {
    print('\n🔍 Verifying AAB with bundletool...');
    final ks = await debugKeystore();
    final apksPath = '${p.withoutExtension(aabPath)}.apks';
    final result = await verifyAabWithBundletool(
      aabPath: aabPath,
      outputApksPath: apksPath,
      keystorePath: ks,
      keyAlias: 'androiddebugkey',
      keyPass: 'android',
      verbose: ctx.verbose,
    );
    if (!result.ok) {
      stderr.writeln('❌ AAB verification failed:\n${result.error}');
      return false;
    }
    print('✅ bundletool accepted the bundle: $apksPath');
    final universalApk = await extractUniversalApk(
      apksPath,
      p.join(p.dirname(aabPath), 'universal', 'app-universal.apk'),
    );
    print('📱 Universal APK extracted: $universalApk');
    print('   Install on a device with:');
    print('     adb install -r $universalApk');
    return true;
  }
}

/// Convenience: typed manifest spec override for Dart composition.
typedef AndroidManifest = ManifestSpec;
