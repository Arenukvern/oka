/// Core contracts for oka: the typed build context, the composable pipeline
/// (`BuildStep`, `Artifact`, `Pipeline`), and the declarative `Oka`
/// composition root (ADR-0006).
///
/// This barrel is the public API of oka_core and is semver-covered. Platform
/// packages (such as `oka_android`) build on these contracts; projects compose
/// them without touching tool invocations.
///
/// ## The pipeline model
///
/// A build is an ordered list of [BuildStep]s. Each step declares what it
/// **provides** and what it **requires** as typed [Artifact]s. The runner
/// validates the whole chain *before any tool runs*, so a mis-wired pipeline
/// fails immediately with an actionable message:
///
/// ```dart
/// final pipeline = Pipeline([
///   AssembleFlutterStep(),   // provides Artifact<Directory>('flutter-assets')
///   StageLayoutStep(),       // requires 'flutter-assets', provides 'apk-path'
/// ]);
/// ```
///
/// ## Custom steps
///
/// Extend [BuildStep] to add project-specific behavior (post-processing the
/// APK, injecting assets, uploading artifacts):
///
/// ```dart
/// class CopyApkStep extends BuildStep {
///   static const apk = Artifact<String>('apk-path');
///
///   @override
///   String get name => 'copy-apk';
///
///   @override
///   Set<Artifact<Object>> get requires => {apk};
///
///   @override
///   Future<StepResult> run(BuildContext ctx, PipelineState state) async {
///     final apkPath = state[apk.id] as String;
///     await File(apkPath).copy('${ctx.projectPath}/app.apk');
///     return StepResult.success();
///   }
/// }
/// ```
///
/// ## Declarative composition
///
/// The entrypoint composes [Oka] with platform pipelines; [okaRun] performs
/// the boilerplate (arg parsing, config merging, directory layout, execution):
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
/// See also:
///
/// * [BuildContext], the immutable configuration every step receives.
/// * [Oka] and [PlatformPipeline], the composition root contract.
/// * [okaRun], the runtime entrypoint for project hooks.
library;

export 'src/composition.dart';
export 'src/config/android_build.dart';
export 'src/config/android_config.dart';
export 'src/config/build_context.dart';
export 'src/config/dependency.dart';
export 'src/config/flutter_config.dart';
export 'src/config/maven_coordinate.dart';
export 'src/config/oka_config.dart';
export 'src/config/plugin_metadata.dart';
export 'src/oka_run.dart';
export 'src/pipeline/pipeline.dart';
export 'src/pipeline_events.dart';
export 'src/process_runner.dart';
