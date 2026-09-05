import 'config/build_context.dart';
import 'pipeline/pipeline.dart';

/// Declarative composition root for an oka build (ADR-0006).
///
/// Const-constructible and immutable — the "Widget" layer of the build:
///
/// ```dart
/// Future<void> main(List<String> args) => okaRun(
///   args,
///   oka: const Oka(
///     pipelines: [
///       AndroidPipeline(config: ..., steps: [...AndroidPipeline.defaultSteps]),
///     ],
///   ),
/// );
/// ```
class Oka {
  /// Platform pipelines to compose. One is selected per build target.
  final List<PlatformPipeline> pipelines;

  const Oka({required this.pipelines});
}

/// A platform-specific pipeline (e.g. `AndroidPipeline` from oka_android).
///
/// Stateless configuration: typed config values + immutable step list. The
/// runtime (memoized artifacts, tool processes) lives in [Pipeline]/steps.
abstract class PlatformPipeline {
  /// Platform selector, matched against `--platform` (default: android).
  String get platform;

  /// Composes and runs this pipeline for [ctx].
  Future<StepResult> run(BuildContext ctx);
}
