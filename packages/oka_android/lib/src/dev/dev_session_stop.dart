/// Cooperative teardown for an owning `oka dev android` process (ADR-0011).
///
/// Does **not** SIGTERM the session first. Prefers the loopback control
/// channel `quit`, then the `--json` stdin `quit` line protocol. A process
/// signal is only a bounded last resort and is reflected in the receipt.
///
/// **Honest limits:** a cleared `runner-session.json` plus exit code 0 only
/// prove the runner executed its exit `finally` — not adb forwards, not
/// device app PID, not attach/daemon descendants. Consumers own those proofs.
library;

import 'dart:async';
import 'dart:io';

import 'dev_control_client.dart';
import 'dev_session.dart';

/// How the owning session was stopped.
enum DevSessionStopDisposition {
  /// Control or stdin `quit`/`detach` accepted; process exited; discovery gone.
  cooperative,

  /// Quit path incomplete; a signal was used to reap the owning process.
  forcedProcessSignal,

  /// Owning process ended but discovery or quit ack did not fully verify.
  incomplete,
}

/// Structured result of [stopOkaDevAndroidSession].
final class DevSessionStopReport {
  const DevSessionStopReport({
    required this.disposition,
    required this.runnerSessionCleared,
    required this.controlQuitAcknowledged,
    required this.elapsed,
    required this.limits,
    this.processExitCode,
    this.controlResponse,
    this.message,
  });

  final DevSessionStopDisposition disposition;
  final int? processExitCode;

  /// `.flutter_mcp/runner-session.json` is absent after stop (spec v2 liveness).
  final bool runnerSessionCleared;

  /// Loopback `quit`/`detach` returned `ok: true`, or stdin quit was written.
  final bool controlQuitAcknowledged;

  final Duration elapsed;

  /// What this API does **not** attest (device forwards, app on device, etc.).
  final String limits;

  final Map<String, Object?>? controlResponse;
  final String? message;

  bool get ok =>
      disposition == DevSessionStopDisposition.cooperative &&
      runnerSessionCleared;
}

/// Stops an owning `oka dev android` [owningProcess] without relying on
/// SIGTERM for discovery cleanup.
///
/// [controlPort] from [readRunnerSessionFile] when available; when null or
/// zero, only the stdin `quit` line is attempted (requires `oka dev android
/// --json`).
Future<DevSessionStopReport> stopOkaDevAndroidSession({
  required Process owningProcess,
  required String projectPath,
  int? controlPort,
  bool stdinJsonQuitEnabled = true,
  Duration quitTimeout = const Duration(seconds: 45),
  Duration discoveryPoll = const Duration(seconds: 10),
}) async {
  const limits =
      'Verifies only owning-process exit and runner-session.json absence. '
      'Does not verify adb reverse/tcp forwards, device app PID, flutter '
      'attach daemon children, or VM port teardown.';
  final watch = Stopwatch()..start();
  Map<String, Object?>? controlResponse;
  var controlQuitAcknowledged = false;

  if (controlPort != null && controlPort > 0) {
    try {
      final client = await DevControlClient.connect(port: controlPort);
      try {
        controlResponse = await client.requestQuit();
        controlQuitAcknowledged = controlResponse['ok'] == true;
      } finally {
        await client.close();
      }
    } on Object catch (e) {
      controlResponse = {'ok': false, 'error': '$e'};
    }
  }

  if (!controlQuitAcknowledged && stdinJsonQuitEnabled) {
    try {
      owningProcess.stdin.writeln('quit');
      await owningProcess.stdin.flush();
      controlQuitAcknowledged = true;
    } on Object {
      // Pipe closed or session not in --json mode.
    }
  }

  int? exitCode;
  var disposition = DevSessionStopDisposition.incomplete;
  try {
    exitCode = await owningProcess.exitCode.timeout(quitTimeout);
    disposition = controlQuitAcknowledged
        ? DevSessionStopDisposition.cooperative
        : DevSessionStopDisposition.incomplete;
  } on TimeoutException {
    owningProcess.kill();
    try {
      exitCode = await owningProcess.exitCode.timeout(
        const Duration(seconds: 5),
      );
    } on TimeoutException {
      owningProcess.kill(ProcessSignal.sigkill);
      exitCode = await owningProcess.exitCode;
    }
    disposition = DevSessionStopDisposition.forcedProcessSignal;
  }

  final runnerSessionCleared = await _waitRunnerSessionAbsent(
    projectPath,
    deadline: DateTime.now().add(discoveryPoll),
  );

  if (disposition == DevSessionStopDisposition.cooperative &&
      (!runnerSessionCleared || exitCode != 0)) {
    disposition = DevSessionStopDisposition.incomplete;
  }

  watch.stop();
  return DevSessionStopReport(
    disposition: disposition,
    processExitCode: exitCode,
    runnerSessionCleared: runnerSessionCleared,
    controlQuitAcknowledged: controlQuitAcknowledged,
    elapsed: watch.elapsed,
    limits: limits,
    controlResponse: controlResponse,
    message: switch (disposition) {
      DevSessionStopDisposition.cooperative =>
        'Session quit accepted; discovery cleared; process exited.',
      DevSessionStopDisposition.forcedProcessSignal =>
        'Quit did not finish within timeout; owning process was signalled.',
      DevSessionStopDisposition.incomplete =>
        'Stop finished with incomplete verification (see receipt fields).',
    },
  );
}

Future<bool> _waitRunnerSessionAbsent(
  String projectPath, {
  required DateTime deadline,
}) async {
  while (DateTime.now().isBefore(deadline)) {
    if (readRunnerSessionFile(projectPath) == null) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return readRunnerSessionFile(projectPath) == null;
}
