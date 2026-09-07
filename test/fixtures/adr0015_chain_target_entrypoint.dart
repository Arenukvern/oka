// ADR-0015 C2 test fixture: a project entrypoint declaring a target whose
// compiled chain has multiple steps exchanging artifacts, so
// `oka explain --targets` output can be asserted end to end (names,
// requires/provides summaries, validation status) without running anything.
import 'package:oka_core/oka_core.dart';

/// Test-only multi-step target: assemble → sign (consumes the artifact the
/// first step provides).
class ChainTarget extends Target {
  const ChainTarget();

  @override
  String get name => 'chain';

  @override
  String get description => 'Test-only two-step target (assemble → sign)';

  @override
  List<BuildStep> compile(final BuildContext ctx) => [AssembleStep(), SignStep()];
}

class AssembleStep extends BuildStep {
  static const out = Artifact<String>('chain-out');

  @override
  String get name => 'chain-assemble';

  @override
  Set<Artifact<Object>> get provides => {out};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) =>
      Future.value(StepResult.success({out.id: 'assembled'}));
}

class SignStep extends BuildStep {
  static const input = Artifact<String>('chain-out');

  @override
  String get name => 'chain-sign';

  @override
  Set<Artifact<Object>> get requires => {input};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) =>
      Future.value(StepResult.success());
}

Future<void> main(final List<String> args) => okaRun(
      args,
      oka: const Oka(pipelines: [], targets: [ChainTarget()]),
    );
