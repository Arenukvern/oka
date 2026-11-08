/// Cooperative teardown for an owning `oka dev android` process (ADR-0011).
///
/// Does **not** SIGTERM the session first. Prefers the loopback control
/// channel `quit`, then the `--json` stdin `quit` line protocol. A process
/// signal is only a bounded last resort and is reflected in the receipt.
///
/// **Honest limits:** a cleared `runner-session.json` plus exit code 0 only
/// prove the runner executed its exit `finally` — not adb forwards, not
/// device app PID, not attach/daemon descendants. Consumers own those proofs.
///
/// **In-session quit vs detach** (before the owning process exits): TCP/stdin
/// `quit` runs [DevSession] teardown (`app.stop` with surfaced RPC errors,
/// optional bounded `pidof` when launch identity is recorded, verified
/// removal of session-created forwards, [FlutterDaemonAdapter.disposeGracefully]).
/// `detach` skips `app.stop`/`pidof` and uses `app.detach` (app keeps running).
/// [DevSessionStopReport] still does not attest device settlement — see
/// [DevSessionTeardownReport.provenPhysicalSettlement].
library;

import 'dart:async';
import 'dart:io';

import 'package:oka_core/oka_core.dart';

import 'dev_control_client.dart';
import 'dev_session.dart';
import 'runner_session_spawn_binding.dart';

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
    required this.controlQuitConnectFailed,
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

  /// A TCP `quit` line was flushed (reply may be lost).
  final bool controlQuitSent;

  /// TCP connect to the live control port failed before any request bytes.
  final bool controlQuitConnectFailed;

  /// Reply lost after [controlQuitSent] (EOF, not connect failure).
  final bool controlReplyLost;

  /// `quit` line written to `--json` stdin (not an ack).
  final bool stdinQuitWritten;

  final Duration elapsed;

  /// What this API does **not** attest (device forwards, app on device, etc.).
  final String limits;

  final Map<String, Object?>? controlResponse;
  final String? message;

  /// Runner discovery + cooperative disposition only (not device settlement).
  ///
  /// False for [provenOwnedResourceSettlement] — adb forwards, device app
  /// PID, and host attach children are not observed here.
  bool get ok =>
      disposition == DevSessionStopDisposition.cooperative &&
      runnerSessionCleared;

  /// Always false on this API: settlement of adb forwards, fixture app PID,
  /// and flutter attach descendants is out of scope (consumer read-only
  /// observations after a settle window).
  bool get provenOwnedResourceSettlement => false;
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
  ProcessTreeProbe spawnBindingProbe = const HostProcessTreeProbe(),
}) async {
  const limits =
      'Verifies only owning-process exit and runner-session.json absence. '
      'Does not verify adb reverse/tcp forwards, device app PID, flutter '
      'attach daemon children, or VM port teardown.';
  final watch = Stopwatch()..start();
  Map<String, Object?>? controlResponse;
  var controlQuitAcknowledged = false;
  var controlQuitSent = false;
  var controlQuitConnectFailed = false;
  var controlReplyLost = false;
  var stdinQuitWritten = false;

  var resolvedControlPort = controlPort;
  final liveDiscovery = readRunnerSessionFile(projectPath);
  if (liveDiscovery == null) {
    // Spec v2 liveness: absent file — never dial a launch-time port (stale /
    // reused ephemeral port risk).
    resolvedControlPort = null;
  } else {
    if (resolvedControlPort == null || resolvedControlPort <= 0) {
      resolvedControlPort = liveDiscovery.controlPort;
    }
    if (resolvedControlPort > 0) {
      final binding = await verifyRunnerSessionSpawnBindingPids(
        discoveryPid: liveDiscovery.pid,
        spawnPid: owningProcess.pid,
        probe: spawnBindingProbe,
      );
      if (!binding.isPlausibleOwnership) {
        resolvedControlPort = null;
        final detail = switch (binding.binding) {
          RunnerSessionSpawnBinding.unrelated =>
            'runner-session pid ${liveDiscovery.pid} not owned by spawn '
            '${owningProcess.pid}',
          RunnerSessionSpawnBinding.unknown =>
            'spawn ownership unverified (invalid pid or process table '
            'unavailable)',
          _ => 'spawn ownership not plausible',
        };
        controlResponse = {
          'ok': false,
          'error': '$detail; skipping control quit',
        };
      } else if (liveDiscovery.controlPort != resolvedControlPort) {
        resolvedControlPort = liveDiscovery.controlPort;
      }
    }
  }

  if (resolvedControlPort != null && resolvedControlPort > 0) {
    DevControlClient? client;
    try {
      client = await DevControlClient.connect(port: resolvedControlPort);
    } on Object catch (e) {
      controlQuitConnectFailed = true;
      controlResponse = {'ok': false, 'error': '$e'};
    }
    if (client != null) {
      try {
        final result = await client.requestQuit(
          timeout: const Duration(seconds: 5),
        );
        controlQuitSent = result.commandFlushed;
        if (result.timedOut) {
          controlResponse = {'ok': false, 'error': 'control request timed out'};
        } else if (result.replyLost && result.commandFlushed) {
          controlReplyLost = true;
          controlResponse = {'ok': false, 'error': 'reply lost (EOF)'};
        } else if (result.replyLost) {
          controlResponse = {
            'ok': false,
            'error': 'reply lost before command flushed',
          };
        } else {
          controlResponse = result.response;
          controlQuitAcknowledged = result.ok;
        }
      } finally {
        try {
          await client.close();
        } on Object {
          // Close failures are not connect failures.
        }
      }
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
    controlQuitConnectFailed: controlQuitConnectFailed,
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
