// Dedicated per-session supervisor: sets child subreaper on itself only, then
// runs the workload. Orphans reparent here — not the gate/test VM.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_dart_kernel/src/gate/linux_child_subreaper.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isLinux) exit(3);
  if (args.length < 2 || args.first != '--') {
    stderr.writeln(
      'usage: linux_subreaper_supervisor.dart -- <executable> [args...]',
    );
    exit(2);
  }
  if (!LinuxChildSubreaper.activate()) {
    stderr.writeln('oka_supervisor: child subreaper unavailable');
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

  var stopping = false;
  Future<void> shutdown() async {
    if (stopping) return;
    stopping = true;
    const probe = HostProcessTreeProbe();
    const liveness = HostProcessLiveness();
  if (child.pid > 0) {
      await stopProcessTree(
        probe: probe,
        liveness: liveness,
        rootPid: child.pid,
      );
    }
    final self = LinuxChildSubreaper.currentProcessId();
    if (self > 0) {
      final tree = await probe.enumerate(self);
      final orphans = tree?.descendants() ?? const <int>[];
      for (final pid in orphans.reversed) {
        await liveness.kill(pid, grace: const Duration(milliseconds: 400));
      }
    }
  }

  ProcessSignal.sigterm.watch().listen((_) async {
    await shutdown();
    exit(143);
  });
  ProcessSignal.sigint.watch().listen((_) async {
    await shutdown();
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
  await shutdown();
  exit(code);
}
