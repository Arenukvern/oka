import 'package:meta/meta.dart';

import '../config/build_context.dart';
import '../pipeline_events.dart';

/// A typed artifact key exchanged between pipeline steps (ADR-0006).
///
/// An artifact is a compile-time-typed handle on a value produced by one step
/// and consumed by downstream steps. Artifact identity is `[T, id]`, so a
/// step declaring `Artifact<Directory>('flutter-assets')` can never read a
/// value stored under the same id with a different type.
///
/// Steps declare artifacts via [BuildStep.requires] / [BuildStep.provides];
/// the runner validates the whole chain at composition time — before any tool
/// runs — and fails naming the missing artifact and the step that needs it.
///
/// ```dart
/// static const stagedApk = Artifact<String>('apk-path');
///
/// @override
/// Set<Artifact<Object>> get provides => {stagedApk};
///
/// @override
/// Future<StepResult> run(BuildContext ctx, PipelineState state) async {
///   state[stagedApk.id] = '${ctx.buildDir}/app.apk';
///   return StepResult.success();
/// }
/// ```
@immutable
class Artifact<T> {
  const Artifact(this.id, {this.description});

  /// Stable identifier, e.g. `'apk-path'`. Unique per provider; the pipeline
  /// fails at composition time if two steps provide the same id.
  final String id;

  /// Optional human-readable description for diagnostics.
  final String? description;

  /// Debug string: artifact id with its type argument.
  @override
  String toString() => 'Artifact<$T>($id)';

  @override
  bool operator ==(final Object other) => other is Artifact<T> && other.id == id;

  /// Hash of id + type (equality is id + type based).
  @override
  int get hashCode => Object.hash(id, T);
}

/// Mutable state shared across pipeline steps.
///
/// The store is keyed by [Artifact.id]. Steps read upstream values and store
/// their own outputs here; prefer typed artifact keys over raw strings so the
/// compiler catches id/type mismatches:
///
/// ```dart
/// @override
/// Future<StepResult> run(BuildContext ctx, PipelineState state) async {
///   final apkPath = state[StagedApkStep.apk.id] as String;
///   // ...
/// }
/// ```
///
/// Platform packages expose typed accessors over this store (see
/// `AndroidPipelineState` in oka_android) for the same reason.
class PipelineState {
  final Map<String, Object?> _values = {};

  Object? operator [](final String key) => _values[key];
  void operator []=(final String key, final Object? value) => _values[key] = value;

  /// All values currently in the store (for diagnostics).
  Map<String, Object?> get snapshot => Map.unmodifiable(_values);
}

/// The outcome of a single pipeline step.
///
/// Steps return [StepResult.success] on success (optionally with diagnostic
/// data) or [StepResult.failure] with a human-readable error. The runner
/// stops at the first failing step and surfaces the error to the CLI:
///
/// ```dart
/// @override
/// Future<StepResult> run(BuildContext ctx, PipelineState state) async {
///   if (!File(manifestPath).existsSync()) {
///     return StepResult.failure(
///       'AndroidManifest.xml not found at $manifestPath',
///     );
///   }
///   return StepResult.success({'manifest': manifestPath});
/// }
/// ```
class StepResult {
  const StepResult({required this.ok, this.error, this.data = const {}});

  /// A successful result, optionally carrying diagnostic [data].
  factory StepResult.success([final Map<String, Object?> data = const {}]) =>
      StepResult(ok: true, data: data);

  /// A failed result. [error] is shown to the user and to driving agents.
  factory StepResult.failure(final String error) =>
      StepResult(ok: false, error: error);

  /// Whether the step completed successfully.
  final bool ok;

  /// Human-readable failure reason; null on success.
  final String? error;

  /// Diagnostic data (timings, artifact paths) for logs and tooling.
  final Map<String, Object?> data;
}

/// A composable unit of the build pipeline (ADR-0006).
///
/// Steps are configuration values: dependencies enter via constructors, and
/// the dataflow contract is declared through [requires] / [provides]. Steps
/// must be idempotent enough to re-run after a failure (oka cleans its own
/// intermediates).
///
/// A minimal custom step that consumes the staged APK:
///
/// ```dart
/// class SizeReportStep extends BuildStep {
///   static const _apk = Artifact<String>('apk-path');
///
///   @override
///   String get name => 'size-report';
///
///   @override
///   Set<Artifact<Object>> get requires => {_apk};
///
///   @override
///   Future<StepResult> run(BuildContext ctx, PipelineState state) async {
///     final apk = File(state[_apk.id] as String);
///     print('APK size: ${apk.lengthSync()} bytes');
///     return StepResult.success();
///   }
/// }
/// ```
///
/// Compose custom steps into the platform pipeline:
///
/// ```dart
/// AndroidPipeline(steps: [...AndroidPipeline.defaultSteps, SizeReportStep()])
/// ```
abstract class BuildStep {
  /// Unique step name, used in logs and YAML overrides (`pipeline.steps`).
  /// Keep it stable: incremental-build caches and pipeline overrides refer
  /// to steps by name.
  String get name;

  /// Artifacts this step needs from upstream steps. Declared up front so the
  /// whole chain is validated before any tool runs.
  Set<Artifact<Object>> get requires => const {};

  /// Artifacts this step makes available to downstream steps. Ids must be
  /// unique across the pipeline.
  Set<Artifact<Object>> get provides => const {};

  /// Executes the step. Read upstream values from [state], write this step's
  /// outputs back into it, and return [StepResult.success] or
  /// [StepResult.failure]. Throw only for programming errors — expected
  /// tool/build failures are reported via the result.
  Future<StepResult> run(final BuildContext ctx, final PipelineState state);
}

/// Runs a list of steps in order, stopping at the first failure.
///
/// Before executing anything, [Pipeline.run] validates the artifact chain:
/// every step's [BuildStep.requires] must be satisfied by an earlier step's
/// [BuildStep.provides]. A violation fails the build immediately with an
/// actionable message — no tool is invoked.
///
/// ```dart
/// final pipeline = Pipeline([
///   AssembleFlutterStep(),
///   StageLayoutStep(),
/// ]);
/// final result = await pipeline.run(context);
/// if (!result.ok) {
///   stderr.writeln(result.error);
///   exit(1);
/// }
/// ```
///
/// Pass [onEvent] to observe structured progress events ([StepStarted],
/// [StepFinished]) — used by `oka explain` and machine-readable output.
class Pipeline {
  Pipeline(this.steps, {this.verbose = false, this.onEvent});

  /// Ordered steps to run.
  final List<BuildStep> steps;

  /// Whether to print per-step progress to stdout.
  final bool verbose;

  /// Optional structured event sink (ADR-0007).
  final void Function(PipelineEvent event)? onEvent;

  /// Validates the artifact chain. Returns an error message, or null.
  String? validate() {
    final provided = <String, String>{}; // artifact id → provider name
    for (final step in steps) {
      for (final req in step.requires) {
        if (!provided.containsKey(req.id)) {
          return 'step "${step.name}" requires ${req.description ?? req.id} '
              '(${req.id}) but no earlier step provides it.\n'
              'Declare a provider before "${step.name}" or drop the '
              'requirement.';
        }
      }
      for (final prov in step.provides) {
        final existing = provided[prov.id];
        if (existing != null && existing != step.name) {
          return 'artifact "${prov.id}" is provided by both "$existing" and '
              '"${step.name}" — artifact ids must be unique per provider.';
        }
        provided[prov.id] = step.name;
      }
    }
    return null;
  }

  Future<StepResult> run(final BuildContext ctx, {final PipelineState? initialState}) async {
    final validationError = validate();
    if (validationError != null) return StepResult.failure(validationError);

    // ADR-0010: platform pipelines may seed the runtime scope (e.g. the
    // merged pipeline-level overrides) — it is the single mutable layer.
    final state = initialState ?? PipelineState();
    void emit(final PipelineEvent e) => onEvent?.call(e);
    for (final step in steps) {
      if (verbose) print('▶ step: ${step.name}');
      emit(StepStarted(step.name));
      final sw = Stopwatch()..start();
      try {
        final result = await step.run(ctx, state);
        emit(
          StepFinished(
            step.name,
            ok: result.ok,
            error: result.error,
            duration: sw.elapsed,
          ),
        );
        if (!result.ok) {
          return StepResult.failure(
            'step "${step.name}" failed: ${result.error}',
          );
        }
      } on Exception catch (e) {
        emit(
          StepFinished(
            step.name,
            ok: false,
            error: e.toString(),
            duration: sw.elapsed,
          ),
        );
        return StepResult.failure('step "${step.name}" threw: $e');
      }
    }
    return StepResult.success({'apk_path': state['apk_path']});
  }
}

/// Shared helper for diagnostics.
@visibleForTesting
String describeArtifacts(final Iterable<Artifact<Object>> artifacts) =>
    artifacts.map((final a) => a.id).join(', ');
