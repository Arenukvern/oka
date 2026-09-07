// ADR-0015 C1 test fixture: an entrypoint declaring a *test double* for the
// device target.
//
// `oka launch` is an alias of `oka run device` — this fixture exercises that
// dispatch path end-to-end without any device/adb involvement: the target
// named `device` writes a marker recording what reached it (so tests can
// assert dispatch equivalence and flag forwarding).
import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';

/// Test double standing in for oka_android's [DeviceTarget] — same name,
/// no device I/O.
class FakeDeviceTarget extends Target {
  const FakeDeviceTarget();

  @override
  String get name => 'device';

  @override
  String get description =>
      'Test double for the device target (writes a marker file)';

  @override
  List<BuildStep> compile(final BuildContext ctx) => [FakeDeviceStep()];
}

class FakeDeviceStep extends BuildStep {
  FakeDeviceStep();

  @override
  String get name => 'fake-device';

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    File('${ctx.buildDir}/device-ran.txt')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'verbose': ctx.verbose,
          'mode': ctx.mode.name,
        }),
      );
    return StepResult.success();
  }
}

Future<void> main(final List<String> args) => okaRun(
      args,
      oka: const Oka(pipelines: [], targets: [FakeDeviceTarget()]),
    );
