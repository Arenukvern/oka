import 'config/build_context.dart';
import 'pipeline/pipeline.dart';
import 'session_state.dart';
import 'targets/target.dart';

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
///         // Workflows not contributed by a target can be composed explicitly.
///         // Targets implementing SessionStateWorkflowContributor contribute
///         // their workflows automatically.
///         sessionStateWorkflows: [],
///       ),
///     );
/// ```
///
/// See also:
///
/// * [okaRun], which performs the boilerplate around this composition.
/// * `AndroidPipeline` (oka_android), the default Android [PlatformPipeline].
class Oka {
  const Oka({
    required this.pipelines,
    this.targets = const [],
    this.sessionStateWorkflows = const [],
  });

  /// Platform pipelines to compose. One is selected per build target by
  /// matching [PlatformPipeline.platform] against `--platform`.
  final List<PlatformPipeline> pipelines;

  /// Project-declared targets (ADR-0015), dispatched via `oka run <target>`
  /// (or a bare `oka <target>` — unknown verbs dispatch to targets). Each
  /// [Target] compiles to a validated step list, so targets get the same
  /// composition-time artifact validation as pipelines. Names are validated
  /// at dispatch: lowercase identifiers, unique, never shadowing a reserved
  /// core verb (`init`, `build`, `run`, ...).
  final List<Target> targets;

  /// Explicit session-state workflows used by `oka session-state` and
  /// `oka doctor` when dispatched through this entrypoint. Workflows exposed
  /// by [SessionStateWorkflowContributor] targets are included automatically
  /// by [effectiveSessionStateWorkflows]. Workflow code remains in this Dart
  /// process; only operation requests and JSON results cross the CLI boundary.
  final List<SessionStateWorkflow<dynamic>> sessionStateWorkflows;

  /// Explicit workflows plus workflows contributed by [targets].
  ///
  /// The same workflow object is included only once when it appears both
  /// explicitly and through one or more targets. Distinct workflow objects
  /// are preserved even if their id and version match, so the normal
  /// composition validation can report genuine conflicts.
  List<SessionStateWorkflow<dynamic>> get effectiveSessionStateWorkflows {
    final workflows = <SessionStateWorkflow<dynamic>>[...sessionStateWorkflows];
    for (final target in targets) {
      if (target is! SessionStateWorkflowContributor) continue;
      final contributor = target as SessionStateWorkflowContributor;
      for (final workflow in contributor.sessionStateWorkflows) {
        if (workflows.any((final existing) => identical(existing, workflow))) {
          continue;
        }
        workflows.add(workflow);
      }
    }
    return List.unmodifiable(workflows);
  }
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
