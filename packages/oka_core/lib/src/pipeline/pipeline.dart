import 'package:meta/meta.dart';

import '../pipeline_events.dart';
import '../config/build_context.dart';

/// Typed artifact key exchanged between pipeline steps (ADR-0006).
///
/// An artifact is a compile-time-typed handle on a value produced by one step
/// and consumed by downstream steps. Artifact identity is `[T, id]`, so a
/// step declaring `Artifact<Directory>('flutter-assets')` can never read a
/// value stored under the same id with a different type.
///
/// Steps declare artifacts via [BuildStep.requires] / [BuildStep.provides];
/// the runner validates the whole chain at composition time — before any tool
/// runs — and fails naming the missing artifact and the step that needs it.
class Artifact<T> {
  /// Stable identifier, e.g. `'apk-path'`.
  final String id;

  /// Optional human-readable description for diagnostics.
  final String? description;

  const Artifact(this.id, {this.description});

  @override
  String toString() => 'Artifact<$T>($id)';

  @override
  bool operator ==(Object other) => other is Artifact<T> && other.id == id;

  @override
  int get hashCode => Object.hash(id, T);
}

/// Mutable state shared across pipeline steps.
///
/// The store is keyed by [Artifact.id]; prefer the typed accessors provided by
/// platform packages (e.g. `AndroidPipelineState` in oka_android) over raw
/// string keys.
class PipelineState {
  final Map<String, Object?> _values = {};

  Object? operator [](String key) => _values[key];
  void operator []=(String key, Object? value) => _values[key] = value;

  /// All values currently in the store (for diagnostics).
  Map<String, Object?> get snapshot => Map.unmodifiable(_values);
}

/// Result of a single pipeline step.
class StepResult {
  final bool ok;
  final String? error;
  final Map<String, Object?> data;

  const StepResult({required this.ok, this.error, this.data = const {}});

  factory StepResult.success([Map<String, Object?> data = const {}]) =>
      StepResult(ok: true, data: data);

  factory StepResult.failure(String error) =>
      StepResult(ok: false, error: error);
}

/// A composable unit of the build pipeline (ADR-0006).
///
/// Steps are configuration values: dependencies enter via constructors, and
/// the dataflow contract is declared through [requires] / [provides]. Steps
/// must be idempotent enough to re-run after a failure (oka cleans its own
/// intermediates).
abstract class BuildStep {
  /// Unique step name, used in logs and YAML overrides (`pipeline.steps`).
  String get name;

  /// Artifacts this step needs from upstream steps.
  Set<Artifact<Object>> get requires => const {};

  /// Artifacts this step makes available to downstream steps.
  Set<Artifact<Object>> get provides => const {};

  Future<StepResult> run(BuildContext ctx, PipelineState state);
}

/// Runs a list of steps in order, stopping at the first failure.
///
/// Before executing anything, [Pipeline.run] validates the artifact chain:
/// every step's [BuildStep.requires] must be satisfied by an earlier step's
/// [BuildStep.provides]. A violation fails the build immediately with an
/// actionable message — no tool is invoked.
class Pipeline {
  final List<BuildStep> steps;
  final bool verbose;

  /// Optional structured event sink (ADR-0007).
  final void Function(PipelineEvent event)? onEvent;

  Pipeline(this.steps, {this.verbose = false, this.onEvent});

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

  Future<StepResult> run(BuildContext ctx, {PipelineState? initialState}) async {
    final validationError = validate();
    if (validationError != null) return StepResult.failure(validationError);

    // ADR-0010: platform pipelines may seed the runtime scope (e.g. the
    // merged pipeline-level overrides) — it is the single mutable layer.
    final state = initialState ?? PipelineState();
    void emit(PipelineEvent e) => onEvent?.call(e);
    for (final step in steps) {
      if (verbose) print('▶ step: ${step.name}');
      emit(StepStarted(step.name));
      final sw = Stopwatch()..start();
      try {
        final result = await step.run(ctx, state);
        emit(
          StepFinished(step.name, result.ok, result.error, sw.elapsed),
        );
        if (!result.ok) {
          return StepResult.failure(
            'step "${step.name}" failed: ${result.error}',
          );
        }
      } on Exception catch (e) {
        emit(StepFinished(step.name, false, e.toString(), sw.elapsed));
        return StepResult.failure('step "${step.name}" threw: $e');
      }
    }
    return StepResult.success({'apk_path': state['apk_path']});
  }
}

/// Shared helper for diagnostics.
@visibleForTesting
String describeArtifacts(Iterable<Artifact<Object>> artifacts) =>
    artifacts.map((a) => a.id).join(', ');
