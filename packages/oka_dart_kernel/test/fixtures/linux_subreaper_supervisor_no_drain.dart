// Test-only supervisor entry: production drain disabled (mutation control).
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:oka_dart_kernel/src/gate/linux_child_subreaper.dart';

Future<void> main(List<String> args) async {
  if (!Platform.isLinux) exit(3);
  if (args.length < 2 || args.first != '--') exit(2);
  final nonce =
      Platform.environment['OKA_DEV_SESSION_NONCE']?.trim() ?? 'missing-nonce';
  if (!LinuxChildSubreaper.activate()) exit(4);

  final child = await Process.start(
    args[1],
    args.sublist(2),
    workingDirectory:
        Platform.environment['OKA_DEV_SESSION_CWD']?.trim().isNotEmpty == true
            ? Platform.environment['OKA_DEV_SESSION_CWD']!.trim()
            : null,
    environment: Platform.environment,
  );
  stderr.writeln('oka_dev_workload_pid=${child.pid}');
  await stderr.flush();

  child.stdout.listen(stdout.add, onDone: () {});
  child.stderr.listen(stderr.add, onDone: () {});
  stdin.cast<List<int>>().listen(child.stdin.add, onDone: child.stdin.close);

  final code = await child.exitCode;
  stderr.writeln(
    'oka_dev_supervisor_drain_ack nonce=$nonce settled=false verified=false survivors=',
  );
  await stderr.flush();
  exit(code);
}
