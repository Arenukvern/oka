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
  if (!LinuxChildSubreaper.activate()) {
    stderr.writeln('oka_supervisor: subreaper unavailable');
    exit(4);
  }

  final executable = args[1];
  final arguments = args.sublist(2);
  final cwd = Platform.environment['OKA_DEV_SESSION_CWD']?.trim();
  final skipDrain = Platform.environment['OKA_SUPERVISOR_SKIP_DRAIN'] == '1';

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
      return drainSubreaperAdoptees(supervisorPid: self).then((d) => d.settled);
    }
    settleOnce = true;
    if (child.pid > 0 && await liveness.isAlive(child.pid)) {
      await stopProcessTree(
        probe: probe,
        liveness: liveness,
        rootPid: child.pid,
      );
    }
    if (skipDrain) return true;
    final drain = await drainSubreaperAdoptees(supervisorPid: self);
    if (!drain.settled) {
      stderr.writeln('oka_supervisor_survivors=${drain.survivors.join(',')}');
    }
    return drain.settled;
  }

  ProcessSignal.sigterm.watch().listen((_) async {
    await settleAll();
    exit(143);
  });
  ProcessSignal.sigint.watch().listen((_) async {
    await settleAll();
    exit(130);
  });

  unawaited(child.stdout.pipe(stdout));
  unawaited(child.stderr.pipe(stderr));
  stdin.cast<List<int>>().listen(
    child.stdin.add,
    onDone: () => child.stdin.close(),
    cancelOnError: true,
  );

  final code = await child.exitCode;
  final settled = await settleAll();
  if (!settled) exit(1);
  exit(code);
}
