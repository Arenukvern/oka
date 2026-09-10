/// The best-effort teardown runner (ADR-0018 §2): executes a target's
/// [Target.compileTeardown] steps after the forward pipeline ends — on
/// success *and* failure — under three laws:
///
/// 1. **Never masks the original result.** Teardown failures are collected
///    and reported as warnings; the caller's exit code / surfaced error is
///    always the forward pipeline's.
/// 2. **Never throws.** A teardown step that throws is a collected failure,
///    not a crash — cleanup must survive a broken step.
/// 3. **Bounded.** Every step runs under [perStepTimeout]; a hung stop (a
///    wedged adb, a browser ignoring its console) cannot hang the run. The
///    force rung of the kill ladder itself lives in the step/seam
///    ([ProcessLiveness.kill]), not here.
///
/// This runner is deliberately *not* `Pipeline.run` (ADR-0018 §2): teardown
/// executes in contexts a build pipeline never does (finally paths, other
/// processes, hours later) and has inverted failure semantics.
///
/// Called by `okaRun` after every target run whose target declares
/// teardown; the runner is public so custom runners (test harnesses, the
/// future session layer) get the identical semantics:
///
/// ```dart
/// final outcome = await runTeardownSteps(
///   target.compileTeardown(ctx),
///   ctx: ctx,
///   state: forwardRunState, // artifacts flow: serial, pid, profile dir
/// );
/// if (!outcome.ok) {
///   // Report — but the build result is already what it is.
///   for (final f in outcome.failures) {
///     stderr.writeln('⚠️ teardown ${f.step}: ${f.error}');
///   }
/// }
/// ```
library;

import 'dart:async';

import 'config/build_context.dart';
import 'pipeline/pipeline.dart';

/// Aggregate outcome of one teardown pass ([runTeardownSteps]).
final class TeardownOutcome {
  const TeardownOutcome(this.failures);

  /// Per-step failures (step name → best-effort reason). Empty = clean.
  final List<({String step, String error})> failures;

  /// Whether every teardown step succeeded (or there were none).
  bool get ok => failures.isEmpty;
}

/// Runs [steps] best-effort in order, each under [perStepTimeout].
///
/// Steps read the forward run's [state] (artifacts like `emulator-serial`
/// or the chrome pid/profile-dir sub-handles) exactly like build steps.
/// Missing artifacts surface as that step's own [StepResult.failure] — the
/// runner never validates the artifact chain up front, because a teardown
/// chain runs against whatever the forward run actually produced.
Future<TeardownOutcome> runTeardownSteps(
  final List<BuildStep> steps, {
  required final BuildContext ctx,
  final PipelineState? state,
  final Duration perStepTimeout = const Duration(seconds: 30),
  final void Function(String line)? write,
}) async {
  final failures = <({String step, String error})>[];
  for (final step in steps) {
    try {
      final result = await step
          .run(ctx, state ?? PipelineState())
          .timeout(perStepTimeout);
      if (!result.ok) {
        failures.add((step: step.name, error: result.error ?? 'failed'));
        write?.call('⚠️ teardown "${step.name}" failed: ${result.error}');
      }
    } on TimeoutException {
      failures.add(
        (step: step.name, error: 'timed out after ${perStepTimeout.inSeconds}s'),
      );
      write?.call(
        '⚠️ teardown "${step.name}" timed out after '
        '${perStepTimeout.inSeconds}s',
      );
    } on Object catch (e) {
      failures.add((step: step.name, error: e.toString()));
      write?.call('⚠️ teardown "${step.name}" threw: $e');
    }
  }
  return TeardownOutcome(failures);
}
