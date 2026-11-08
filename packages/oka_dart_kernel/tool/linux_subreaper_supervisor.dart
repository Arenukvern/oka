// Dedicated per-session supervisor: sets child subreaper on itself only, then
// runs the workload. Orphans reparent here — not the gate/test VM.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_dart_kernel/src/gate/linux_child_subreaper.dart';
import 'package:oka_dart_kernel/src/gate/linux_subreaper_drain.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isLinux) exit(3);
  if (args.length < 2 || args.first != '--') {
    stderr.writeln(
      'usage: linux_subreaper_supervisor.dart -- <executable> [args...]',
    );
    exit(2);
  }

  final nonce =
      Platform.environment['OKA_DEV_SESSION_NONCE']?.trim() ?? 'missing-nonce';

  if (!LinuxChildSubreaper.activate()) {
    stderr.writeln(
      'oka_dev_supervisor_drain_ack nonce=$nonce settled=false verified=false survivors=',
    );
    exit(4);
  }

  final executable = args[1];
  final arguments = args.sublist(2);
  final cwd = Platform.environment['OKA_DEV_SESSION_CWD']?.trim();

  final child = await Process.start(
    executable,
    arguments,
    workingDirectory: cwd?.isNotEmpty == true ? cwd : null,
    environment: Platform.environment,
  );
  stderr.writeln('oka_dev_workload_pid=${child.pid}');
  await stderr.flush();

  final self = LinuxChildSubreaper.currentProcessId();
  const probe = HostProcessTreeProbe();
  const liveness = HostProcessLiveness();
  var settleOnce = false;

  Future<bool> settleAll() async {
    if (settleOnce) {
      final drain = await drainSubreaperAdoptees(supervisorPid: self);
      final surv = drain.survivors.isEmpty ? '' : drain.survivors.join(',');
      stderr.writeln(
        'oka_dev_supervisor_drain_ack nonce=$nonce '
        'settled=${drain.settled} verified=${drain.verified} survivors=$surv',
      );
      return drain.settled && drain.verified && drain.survivors.isEmpty;
    }
    settleOnce = true;
    if (child.pid > 0 && await liveness.isAlive(child.pid)) {
      await stopProcessTree(
        probe: probe,
        liveness: liveness,
        rootPid: child.pid,
      );
    }
    final drain = await drainSubreaperAdoptees(supervisorPid: self);
    final surv = drain.survivors.isEmpty ? '' : drain.survivors.join(',');
    stderr.writeln(
      'oka_dev_supervisor_drain_ack nonce=$nonce '
      'settled=${drain.settled} verified=${drain.verified} survivors=$surv',
    );
    return drain.settled && drain.verified && drain.survivors.isEmpty;
  }

  ProcessSignal.sigterm.watch().listen((_) async {
    await settleAll();
    exit(143);
  });
  ProcessSignal.sigint.watch().listen((_) async {
    await settleAll();
    exit(130);
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

  final code = await child.exitCode;
  final ok = await settleAll();
  if (!ok) exit(1);
  exit(code);
}
