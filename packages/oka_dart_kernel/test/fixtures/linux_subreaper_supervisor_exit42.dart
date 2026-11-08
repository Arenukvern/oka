// Test-only: emits a successful control ack then abnormal supervisor exit 42.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:oka_dart_kernel/src/gate/linux_child_subreaper.dart';
import 'package:oka_dart_kernel/src/gate/supervisor_control_channel.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isLinux) exit(3);
  if (args.length < 2 || args.first != '--') exit(2);
  final nonce =
      Platform.environment[kSupervisorNonceEnv]?.trim() ?? 'missing-nonce';
  if (!LinuxChildSubreaper.activate()) exit(4);

  final child = await Process.start(
    args[1],
    args.sublist(2),
    workingDirectory:
        Platform.environment['OKA_DEV_SESSION_CWD']?.trim().isNotEmpty == true
            ? Platform.environment['OKA_DEV_SESSION_CWD']!.trim()
            : null,
    environment: sanitizeWorkloadEnvironment(Platform.environment),
  );
  await appendSupervisorControlLine('oka_dev_workload_pid=${child.pid}');
  child.stdout.listen(stdout.add, onDone: () {});
  child.stderr.listen(stderr.add, onDone: () {});
  stdin.cast<List<int>>().listen(child.stdin.add, onDone: child.stdin.close);
  final workloadExit = await child.exitCode;
  await appendSupervisorControlLine(
    'oka_dev_supervisor_drain_ack nonce=$nonce settled=true verified=true survivors=',
  );
  await appendSupervisorControlLine(
    'oka_dev_supervisor_shutdown supervisor_exit=42 workload_exit=$workloadExit',
  );
  exit(42);
}
