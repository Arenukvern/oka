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
  /// Quit requested; process exited; discovery gone (see receipt flags).
  cooperative,

  /// Quit path incomplete; a signal was used to reap the owning process.
  forcedProcessSignal,

  /// Owning process ended but discovery or quit path did not fully verify.
  incomplete,
}

/// Structured result of [stopOkaDevAndroidSession].
final class DevSessionStopReport {
  const DevSessionStopReport({
    required this.disposition,
    required this.runnerSessionCleared,
    required this.controlQuitAcknowledged,
    required this.controlQuitSent,
    required this.controlReplyLost,
    required this.stdinQuitWritten,
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

  /// Loopback `quit`/`detach` returned `ok: true` on the wire.
  final bool controlQuitAcknowledged;

  /// A TCP `quit`/`detach` was sent (even if the reply was lost).
  final bool controlQuitSent;

  /// Reply line never arrived (EOF / server tore down first).
  final bool controlReplyLost;

  /// `quit` line written to `--json` stdin (not an ack).
  final bool stdinQuitWritten;

  final Duration elapsed;

  /// What this API does **not** attest (device forwards, app on device, etc.).
  final String limits;

  final Map<String, Object?>? controlResponse;
  final String? message;

  /// Runner discovery + cooperative disposition only (not device settlement).
  bool get ok =>
      disposition == DevSessionStopDisposition.cooperative &&
      runnerSessionCleared;
}

/// Stops an owning `oka dev android` [owningProcess] without relying on
/// SIGTERM for discovery cleanup.
Future<DevSessionStopReport> stopOkaDevAndroidSession({
  required Process owningProcess,
  required String projectPath,
  int? controlPort,
  bool stdinJsonQuitEnabled = true,
  Duration quitTimeout = const Duration(seconds: 45),
  Duration discoveryPoll = const Duration(seconds: 10),
  Duration forceSignalGrace = const Duration(seconds: 5),
}) async {
  const limits =
      'Verifies only owning-process exit and runner-session.json absence. '
      'Does not verify adb reverse/tcp forwards, device app PID, flutter '
      'attach daemon children, or VM port teardown.';
  final watch = Stopwatch()..start();
  Map<String, Object?>? controlResponse;
  var controlQuitAcknowledged = false;
  var controlQuitSent = false;
  var controlReplyLost = false;
  var stdinQuitWritten = false;

  if (controlPort != null && controlPort > 0) {
    controlQuitSent = true;
    try {
      final client = await DevControlClient.connect(port: controlPort);
      try {
        final result = await client.requestQuit(
          timeout: const Duration(seconds: 5),
        );
        if (result.timedOut) {
          controlResponse = {'ok': false, 'error': 'control request timed out'};
        } else if (result.replyLost) {
          controlReplyLost = true;
          controlResponse = {'ok': false, 'error': 'reply lost (EOF)'};
        } else {
          controlResponse = result.response;
          controlQuitAcknowledged = result.ok;
        }
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
      stdinQuitWritten = true;
    } on Object {
      // Pipe closed or session not in --json mode.
    }
  }

  final quitRequested = controlQuitSent || stdinQuitWritten;

  int? exitCode;
  var disposition = DevSessionStopDisposition.incomplete;
  try {
    exitCode = await owningProcess.exitCode.timeout(quitTimeout);
  } on TimeoutException {
    owningProcess.kill();
    try {
      exitCode = await owningProcess.exitCode.timeout(forceSignalGrace);
    } on TimeoutException {
      owningProcess.kill(ProcessSignal.sigkill);
      try {
        exitCode = await owningProcess.exitCode.timeout(forceSignalGrace);
      } on TimeoutException {
        exitCode = null;
      }
    }
    disposition = DevSessionStopDisposition.forcedProcessSignal;
  }

  final runnerSessionCleared = await _waitRunnerSessionAbsent(
    projectPath,
    deadline: DateTime.now().add(discoveryPoll),
  );

  if (disposition != DevSessionStopDisposition.forcedProcessSignal) {
    final cleanExit = exitCode == 0;
    final quitPathHonest = controlQuitAcknowledged ||
        stdinQuitWritten ||
        (controlReplyLost && controlQuitSent);
    if (cleanExit && runnerSessionCleared && quitRequested && quitPathHonest) {
      disposition = DevSessionStopDisposition.cooperative;
    } else {
      disposition = DevSessionStopDisposition.incomplete;
    }
  }

  watch.stop();
  return DevSessionStopReport(
    disposition: disposition,
    processExitCode: exitCode,
    runnerSessionCleared: runnerSessionCleared,
    controlQuitAcknowledged: controlQuitAcknowledged,
    controlQuitSent: controlQuitSent,
    controlReplyLost: controlReplyLost,
    stdinQuitWritten: stdinQuitWritten,
    elapsed: watch.elapsed,
    limits: limits,
    controlResponse: controlResponse,
    message: switch (disposition) {
      DevSessionStopDisposition.cooperative =>
        'Quit requested; discovery cleared; owning process exited.',
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
