// ADR-0015 test fixture: a project entrypoint declaring a target.
//
// Used by test/adr0015_target_dispatch_test.dart to exercise the CLI
// dispatcher's entrypoint loading (`--oka-list-targets`) and target
// delegation (`--oka-run-target`) without touching a real Flutter project.
import 'dart:io';

import 'package:oka_core/oka_core.dart';

/// Test-only target: writes a marker file so tests can observe execution.
class EchoTarget extends Target {
  const EchoTarget();

  @override
  String get name => 'echo';

  @override
  String get description => 'Test-only no-op target (writes a marker file)';

  @override
  List<BuildStep> compile(final BuildContext ctx) => [EchoStep()];
}

class EchoStep extends BuildStep {
  EchoStep();

  @override
  String get name => 'echo';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    File('${ctx.buildDir}/echo-ran.txt')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('echo');
    return StepResult.success();
  }
}

Future<void> main(final List<String> args) => okaRun(
      args,
      oka: const Oka(pipelines: [], targets: [EchoTarget()]),
    );
