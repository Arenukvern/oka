import 'package:oka_core/oka_core.dart';

import 'build/dependency_cache.dart';
import 'build/launcher_icon.dart';
import 'build/sdk_locator.dart';
import 'manifest_spec.dart';
import 'pipeline/default_pipeline.dart';
import 'pipeline/steps/flutter_steps.dart';
import 'pipeline/steps/host_steps.dart';
import 'pipeline/steps/tool_steps.dart';
import 'signing_config.dart';

/// Declarative Android platform pipeline (ADR-0006).
///
/// Immutable configuration value: [overrides] (typed, [copyWith]-able) plus an
/// optional step list. When [steps] is null the default no-Gradle pipeline is
/// composed (APK or AAB depending on [BuildContext.buildAab]).
///
/// ```dart
/// AndroidPipeline(
///   overrides: PipelineOverrides().copyWith(resourceConfigs: ['en', 'ru']),
///   steps: [...AndroidPipeline.defaultSteps, MyStep()],
/// )
/// ```
class AndroidPipeline implements PlatformPipeline {
  /// Typed fast-settings (deps, assets, deeplinks, icon, manifest, signing).
  final PipelineOverrides overrides;

  /// Full step list. Null → [defaultSteps] (behavior-preserving default).
  final List<BuildStep>? steps;

  /// Whether unsupported plugins abort the build (strict) or warn (soft).
  final bool strictPlugins;

  @override
  String get platform => 'android';

  const AndroidPipeline({
    this.overrides = const PipelineOverrides(),
    this.steps,
    this.strictPlugins = true,
  });

  AndroidPipeline copyWith({
    PipelineOverrides? overrides,
    List<BuildStep>? steps,
    bool? strictPlugins,
  }) => AndroidPipeline(
    overrides: overrides ?? this.overrides,
    steps: steps ?? this.steps,
    strictPlugins: strictPlugins ?? this.strictPlugins,
  );

  /// The default step sequence (fresh instances; services resolve lazily).
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
      CompileAndDexStep(sdkLocator: sdkLocator),
      PackageAndSignStep(sdkLocator: sdkLocator),
      ValidateLayoutStep(),
    ];
  }

  @override
  Future<StepResult> run(BuildContext ctx) async {
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
    return pipeline.run(ctx);
  }
}

/// Convenience: typed manifest spec override for Dart composition.
typedef AndroidManifest = ManifestSpec;
