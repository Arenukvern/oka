import 'config/build_context.dart';
import 'pipeline/pipeline.dart';

/// The declarative composition root for an oka build (ADR-0006).
///
/// `Oka` is the "widget tree" of the build: const-constructible, immutable,
/// and fully type-checked at compile time. A project entrypoint composes one
/// or more [PlatformPipeline]s — oka selects the pipeline matching the
/// `--platform` CLI argument (default: `android`):
///
/// ```dart
/// // tool/oka_pipeline.dart — the project IS the config (ADR-0010).
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
/// * [okaRun], which performs the boilerplate around this composition.
/// * `AndroidPipeline` (oka_android), the default Android [PlatformPipeline].
class Oka {
  const Oka({required this.pipelines});

  /// Platform pipelines to compose. One is selected per build target by
  /// matching [PlatformPipeline.platform] against `--platform`.
  final List<PlatformPipeline> pipelines;
}

/// A platform-specific pipeline (e.g. `AndroidPipeline` from oka_android).
///
/// Stateless configuration: typed config values + immutable step list. The
/// runtime (memoized artifacts, tool processes) lives in [Pipeline]/steps.
///
/// Implementations keep three invariants:
///
/// * [platform] is a stable selector string (`'android'`, `'ios'`, ...).
/// * [configOverrides] is a pure function of the typed config — it must not
///   read the filesystem or environment.
/// * [run] validates its artifact chain before invoking any tool.
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
  Future<StepResult> run(final BuildContext ctx);
}
