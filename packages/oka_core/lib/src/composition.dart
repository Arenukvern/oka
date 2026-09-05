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

  /// Typed config materialized into the build context (ADR-0010). Deep-merged
  /// **over** the project's `oka.yaml` map (if present) by `okaRun` — every
  /// config consumer keeps reading `ctx.config`, so pipeline steps cannot
  /// tell whether a value came from YAML or from Dart. Empty by default:
  /// yaml-only projects are unaffected.
  Map<String, dynamic> get configOverrides => const {};

  /// Composes and runs this pipeline for [ctx].
  Future<StepResult> run(BuildContext ctx);
}
