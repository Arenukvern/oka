// ADR-0015 test fixture: a project entrypoint declaring an **invalid**
// target — its compiled step requires an artifact no earlier step provides.
//
// Used by test/adr0015_target_dispatch_test.dart to prove that target
// pipelines go through the same composition-time artifact validation as
// builds (Pipeline.validate) *before any tool runs*.
import 'package:oka_core/oka_core.dart';

/// Test-only target whose compiled pipeline is invalid.
class BrokenTarget extends Target {
  const BrokenTarget();

  @override
  String get name => 'broken';

  @override
  String get description => 'Test-only target with an unsatisfied require';

  @override
  List<BuildStep> compile(final BuildContext ctx) => [BrokenStep()];
}

class BrokenStep extends BuildStep {
  BrokenStep();

  static const missing = Artifact<String>('never-provided');

  @override
  String get name => 'broken-step';

  @override
  Set<Artifact<Object>> get requires => {missing};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) {
    throw StateError('broken-step must never run — validation must catch it');
  }
}

Future<void> main(final List<String> args) => okaRun(
      args,
      oka: const Oka(pipelines: [], targets: [BrokenTarget()]),
    );
