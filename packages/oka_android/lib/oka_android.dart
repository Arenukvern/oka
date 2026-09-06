/// Android platform pipelines for oka: no-Gradle Flutter APK/AAB build steps,
/// plugin packaging, the direct Android SDK toolchain (`aapt2`, `d8`,
/// `apksigner`), and typed manifest/spec values (ADR-0006).
///
/// This is the package hook authors depend on. It re-exports `oka_core` and
/// adds everything Android-specific — no CLI/AI surface.
///
/// ## Building with the default pipeline
///
/// [AndroidPipeline] composes the full no-Gradle pipeline by default. An
/// entrypoint only needs to declare it, optionally with typed config
/// (ADR-0010) that deep-merges over any `oka.yaml`:
///
/// ```dart
/// import 'package:oka_android/oka_android.dart';
/// import 'package:oka_core/oka_core.dart';
///
/// Future<void> main(List<String> args) => okaRun(
///       args,
///       oka: const Oka(
///         pipelines: [
///           AndroidPipeline(
///             config: AndroidBuild(
///               packageName: 'dev.example.app',
///               minSdk: '23',
///               abis: ['arm64-v8a'],
///             ),
///             flutterConfig: FlutterBuild(
///               entrypoint: 'lib/main.dart',
///             ),
///           ),
///         ],
///       ),
///     );
/// ```
///
/// Run it with `oka build apk --release` (oka discovers
/// `tool/oka_pipeline.dart` by convention) or `dart run` it directly.
///
/// ## Customizing steps
///
/// Steps are immutable values. Append, replace, or remove them to reshape the
/// pipeline — the artifact chain is re-validated at composition time:
///
/// ```dart
/// AndroidPipeline(
///   steps: [
///     ...AndroidPipeline.defaultSteps,
///     NotarizeApkStep(), // your BuildStep; requires 'apk-path'
///   ],
/// )
/// ```
///
/// ## Fast settings
///
/// [PipelineOverrides] groups packaging-level fast settings — extra Maven
/// deps, local AARs, deeplinks, launcher icon, signing, resource configs:
///
/// ```dart
/// AndroidPipeline(
///   overrides: const PipelineOverrides(
///     extraDeps: ['androidx.core:core-ktx:1.13.1'],
///     localAars: ['libs/analytics.aar'],
///     resourceConfigs: ['en', 'de'],
///     icon: IconConfig(backgroundColor: '#E8F5E9'),
///   ),
/// )
/// ```
///
/// See also:
///
/// * [AndroidPipeline.defaultSteps], the default step chain.
/// * [DependencyCache] and [MavenResolver], the dependency resolution layer.
/// * [SdkLocator], which finds (or bootstraps, `oka get android-sdk`) the
///   Android SDK.
library;

export 'package:oka_core/oka_core.dart';

// Artifact keys, typed state accessors, and the platform pipeline.
export 'src/android_artifacts.dart';
export 'src/android_pipeline.dart';
export 'src/android_state.dart';
export 'src/auto_resolve.dart';

// Build machinery.
export 'src/build/aab_layout.dart';
export 'src/build/aapt2_commands.dart';
export 'src/build/android_builder.dart';
export 'src/build/android_sdk_installer.dart';
export 'src/build/apk_layout.dart';
export 'src/build/bundletool.dart';
export 'src/build/dependency_cache.dart';
export 'src/build/dependency_suggest.dart';
export 'src/build/engine_artifacts.dart';
export 'src/build/flutter_apk_builder.dart';
export 'src/build/flutter_assemble.dart';
export 'src/build/flutter_asset_bundler.dart';
export 'src/build/gradle_dep_parser.dart';
export 'src/build/host_codegen.dart';
export 'src/build/java_environment.dart';
export 'src/build/launcher_icon.dart';
export 'src/build/plugin_discovery.dart';
export 'src/build/plugin_packager.dart';
export 'src/build/sdk_locator.dart';
export 'src/build/version_manager.dart';
export 'src/build_cache.dart';
export 'src/compare.dart';
export 'src/dependency_plan.dart';

// Platform pipeline + specs.
export 'src/manifest_spec.dart';
export 'src/maven_resolver.dart';
export 'src/pipeline/default_pipeline.dart';
export 'src/pipeline/steps/asset_steps.dart';
export 'src/pipeline/steps/flutter_steps.dart';
export 'src/pipeline/steps/host_steps.dart';
export 'src/pipeline/steps/tool_steps.dart';
export 'src/pipeline/toolchain.dart';
export 'src/post_build_lint.dart';
export 'src/signing_config.dart';
