import 'dart:async';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_dart_kernel/src/gate/dev_gate_signals.dart';
import 'package:oka_dart_kernel/src/gate/owned_dev_session.dart';
import 'package:oka_dart_kernel/src/gate/owned_dev_session_start_controller.dart';

/// SIGTERM during session start (identity still in flight), not after `dev: ready`.
Future<void> main(List<String> args) async {
  final workspace = args[0];
  final stub = args[1];
  final startCtl = OwnedDevSessionStartController();
  DevGateSignalCoordinator(onSignal: startCtl.requestAbort).install();

  stdout.writeln('GATE_STARTUP_DRIVER_READY');
  try {
    await OwnedDevSession.start(
      workspace: workspace,
      dartInvocation: [stub],
      useSubreaperSupervisor: false,
      startController: startCtl,
      liveness: const _StartupSlowLiveness(),
      identityBudget: const Duration(seconds: 2),
    );
  } on Object {
    exit(2);
  }
  exit(0);
}

final class _StartupSlowLiveness implements ProcessLiveness {
  const _StartupSlowLiveness();

  @override
  Future<String?> identityToken(int pid) async {
    await Future<void>.delayed(const Duration(seconds: 5));
    return const HostProcessLiveness().identityToken(pid);
  }

  @override
  Future<bool> isAlive(int pid) => const HostProcessLiveness().isAlive(pid);

  @override
  Future<bool> kill(int pid, {Duration grace = const Duration(seconds: 3)}) =>
      const HostProcessLiveness().kill(pid, grace: grace);
}
