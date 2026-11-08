// Subprocess entry for SIGTERM → gate owner cleanup regression (not unit mocks).
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_dart_kernel/src/gate/dev_gate_signals.dart';
import 'package:oka_dart_kernel/src/gate/linux_dev_gate.dart';
import 'package:oka_dart_kernel/src/gate/owned_dev_session.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) exit(2);
  final workspace = args[0];
  final stub = args[1];
  final gate = LinuxDevGate(workspace: workspace);
  final session = await OwnedDevSession.start(
    workspace: workspace,
    dartInvocation: [stub, '--hang-on-quit'],
  );
  gate.bindActiveSessionForTesting(session);
  if (!await session.waitForPattern('dev: ready', timeout: const Duration(seconds: 15))) {
    stderr.writeln('driver: never became ready');
    exit(2);
  }
  await session.snapshotOwnedTree();
  final tracked = session.ownedTree?.allTrackedPids ?? <int>[];
  stdout.writeln('GATE_SIG_TRACKED:${jsonEncode(tracked)}');
  stdout.writeln('GATE_SIG_REGRESSION_READY');
  await stdout.flush();
  DevGateSignalCoordinator(
    onSignal: () => gate.interruptCleanup(
      quitGrace: const Duration(milliseconds: 300),
    ),
  ).install();
  await Completer<void>().future;
}
