// Dedicated per-session supervisor: sets child subreaper on itself only, then
// runs the workload. Orphans reparent here — not the gate/test VM.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_dart_kernel/src/gate/linux_child_subreaper.dart';
import 'package:oka_dart_kernel/src/gate/linux_subreaper_drain.dart';
import 'package:oka_dart_kernel/src/gate/linux_subreaper_settle_coordinator.dart';
import 'package:oka_dart_kernel/src/gate/supervisor_control_channel.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isLinux) exit(3);
  if (args.length < 2 || args.first != '--') {
    stderr.writeln(
      'usage: linux_subreaper_supervisor.dart -- <executable> [args...]',
    );
    exit(2);
  }

  final nonce =
      Platform.environment[kSupervisorNonceEnv]?.trim() ?? 'missing-nonce';

  if (!LinuxChildSubreaper.activate()) {
    await appendSupervisorControlLine(
      'oka_dev_supervisor_drain_ack nonce=$nonce settled=false verified=false survivors=',
    );
    exit(4);
  }

  final executable = args[1];
  final arguments = args.sublist(2);
  final cwd = Platform.environment['OKA_DEV_SESSION_CWD']?.trim();

  await ensureSupervisorControlWriter();
  final child = await Process.start(
    executable,
    arguments,
    workingDirectory: cwd?.isNotEmpty == true ? cwd : null,
    environment: workloadProcessEnvironment(),
    includeParentEnvironment: false,
  );
  await appendSupervisorControlLine('oka_dev_workload_pid=${child.pid}');

  final self = LinuxChildSubreaper.currentProcessId();
  const probe = HostProcessTreeProbe();
  const liveness = HostProcessLiveness();
  final settleCoordinator = LinuxSubreaperSettleCoordinator();

  Future<bool> settleAll() => settleCoordinator.settleOnce(
        () => _runSettle(
          child: child,
          self: self,
          probe: probe,
          liveness: liveness,
          nonce: nonce,
        ),
      );

  ProcessSignal.sigterm.watch().listen((_) async {
    final ok = await settleAll();
    final workloadExit = child.pid > 0 ? await child.exitCode.catchError((_) => -1) : -1;
    await appendSupervisorControlLine(
      'oka_dev_supervisor_shutdown supervisor_exit=${ok ? 143 : 1} workload_exit=$workloadExit',
    );
    exit(ok ? 143 : 1);
  });
  ProcessSignal.sigint.watch().listen((_) async {
    final ok = await settleAll();
    final workloadExit = child.pid > 0 ? await child.exitCode.catchError((_) => -1) : -1;
    await appendSupervisorControlLine(
      'oka_dev_supervisor_shutdown supervisor_exit=${ok ? 130 : 1} workload_exit=$workloadExit',
    );
    exit(ok ? 130 : 1);
  });

  child.stdout.listen(
    stdout.add,
    onError: (_) {},
    onDone: () {},
    cancelOnError: true,
  );
  child.stderr.listen(
    stderr.add,
    onError: (_) {},
    onDone: () {},
    cancelOnError: true,
  );
  stdin.cast<List<int>>().listen(
    child.stdin.add,
    onDone: () => child.stdin.close(),
    cancelOnError: true,
  );

  final workloadExit = await child.exitCode;
  final drainOk = await settleAll();
  final supervisorExit = drainOk ? 0 : 1;
  await appendSupervisorControlLine(
    'oka_dev_supervisor_shutdown supervisor_exit=$supervisorExit workload_exit=$workloadExit',
  );
  exit(supervisorExit);
}

Future<bool> _runSettle({
  required Process child,
  required int self,
  required HostProcessTreeProbe probe,
  required HostProcessLiveness liveness,
  required String nonce,
}) async {
  final surv = (List<int> s) => s.isEmpty ? '' : s.join(',');
  Future<void> emitAck(SubreaperDrainResult drain) async {
    await appendSupervisorControlLine(
      'oka_dev_supervisor_drain_ack nonce=$nonce '
      'settled=${drain.settled} verified=${drain.verified} '
      'survivors=${surv(drain.survivors)}',
    );
  }

  try {
    if (child.pid > 0 && await liveness.isAlive(child.pid)) {
      await stopProcessTree(
        probe: probe,
        liveness: liveness,
        rootPid: child.pid,
      );
    }
    final drain = await drainSubreaperAdoptees(supervisorPid: self);
    await emitAck(drain);
    return drain.settled && drain.verified && drain.survivors.isEmpty;
  } on Object catch (e) {
    final fail = SubreaperDrainResult(
      settled: false,
      verified: false,
      survivors: const [],
      notes: ['settle error: $e'],
    );
    await emitAck(fail);
    return false;
  }
}
