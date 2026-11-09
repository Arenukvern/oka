/// Physical teardown helpers for `oka dev android` (SDK-owned resources only).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'adb_tool.dart';
import 'daemon_adapter.dart';
import 'dev_session_teardown_budget.dart';

/// Exact adb forward triplet recorded when the session created the mapping.
final class DevSessionCreatedForward {
  const DevSessionCreatedForward({
    required this.deviceSerial,
    required this.hostLocalPort,
    required this.deviceRemotePort,
    required this.recordedAt,
  });

  final String deviceSerial;
  final int hostLocalPort;
  final int deviceRemotePort;
  final DateTime recordedAt;
}

/// Launch-time package on [deviceSerial] (install/launch pipeline only).
final class DevSessionLaunchIdentity {
  const DevSessionLaunchIdentity({
    required this.deviceSerial,
    required this.packageName,
  });

  final String deviceSerial;
  final String packageName;
}

/// Attach host child at spawn — diagnostic only (no child-reap authority).
final class AttachHostProcessIdentity {
  const AttachHostProcessIdentity({
    required this.attachPid,
    required this.spawnEpoch,
  });

  final int attachPid;

  /// Wall-clock spawn instant — not OS process start time.
  final DateTime spawnEpoch;
}

AttachHostProcessIdentity? attachHostIdentityFor(DaemonTransport transport) {
  if (transport is ProcessDaemonTransport) {
    return AttachHostProcessIdentity(
      attachPid: transport.pid,
      spawnEpoch: transport.startedAt,
    );
  }
  return null;
}

/// Resources the SDK created during this attach round.
final class DevSessionResourceOwnership {
  const DevSessionResourceOwnership({
    required this.adbPath,
    this.vmServiceForward,
    this.launchIdentity,
    this.runAdb,
  });

  final String adbPath;
  final DevSessionCreatedForward? vmServiceForward;
  final DevSessionLaunchIdentity? launchIdentity;

  /// Test hook — production uses [runAdbBounded].
  final AdbArgvRunner? runAdb;
}

/// One parsed `adb forward --list` row (`serial tcp:local tcp:remote`).
final class AdbForwardListEntry {
  const AdbForwardListEntry({
    required this.serial,
    required this.hostLocalPort,
    required this.deviceRemotePort,
  });

  final String serial;
  final int hostLocalPort;
  final int deviceRemotePort;
}

List<AdbForwardListEntry> parseAdbForwardList(String output) {
  final entries = <AdbForwardListEntry>[];
  final lineRe = RegExp(r'^(\S+)\s+tcp:(\d+)\s+tcp:(\d+)\s*$');
  for (final raw in output.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('List')) continue;
    final m = lineRe.firstMatch(line.replaceFirst('\t', ''));
    if (m == null) continue;
    entries.add(
      AdbForwardListEntry(
        serial: m.group(1)!,
        hostLocalPort: int.parse(m.group(2)!),
        deviceRemotePort: int.parse(m.group(3)!),
      ),
    );
  }
  return entries;
}

List<String> adbForwardListArgs({String? serial}) => [
  ...adbSerialArgs(serial),
  'forward',
  '--list',
];

final class ForwardListAction {
  const ForwardListAction({
    required this.ok,
    this.entries = const [],
    this.adbExitCode,
    this.message,
    this.timedOut = false,
  });

  final bool ok;
  final List<AdbForwardListEntry> entries;
  final int? adbExitCode;
  final String? message;
  final bool timedOut;
}

final class ForwardReleaseAction {
  const ForwardReleaseAction({
    required this.attempted,
    required this.removed,
    this.alreadyAbsent = false,
    this.refusedConcurrencyMismatch = false,
    this.listFailed = false,
    this.adbExitCode,
    this.message,
  });

  final bool attempted;
  final bool removed;
  final bool alreadyAbsent;
  final bool refusedConcurrencyMismatch;
  final bool listFailed;
  final int? adbExitCode;
  final String? message;
}

final class AppStopAction {
  const AppStopAction({
    required this.rpcOk,
    required this.duration,
    this.errorText,
    this.resultSummary,
    this.timedOut = false,
    this.stopEventSeen = false,
  });

  final bool rpcOk;
  final Duration duration;
  final String? errorText;
  final String? resultSummary;
  final bool timedOut;
  final bool stopEventSeen;
}

final class ForceStopAction {
  const ForceStopAction({
    required this.attempted,
    required this.commandOk,
    this.adbExitCode,
    this.message,
    this.timedOut = false,
  });

  final bool attempted;
  final bool commandOk;
  final int? adbExitCode;
  final String? message;
  final bool timedOut;
}

/// Outcome of interpreting one `adb shell pidof` sample on a verified shell.
enum PidofAbsentSignal {
  /// Process still running (stdout has pid token(s)).
  present,

  /// Package not running (`pidof` exit 0 or 1 with empty stdout on Android).
  absent,

  /// Device/shell transport or authorization failure.
  transportFailure,

  /// Healthy shell but pidof outcome not attributable (fail-closed).
  inconclusive,
}

/// Pure Android pidof semantics (exit 1 + empty = not running when shell OK).
PidofAbsentSignal interpretPidofAbsentProbe({
  required int exitCode,
  required String stdout,
  required String stderr,
  required bool deviceShellHealthy,
}) {
  if (!deviceShellHealthy) {
    return PidofAbsentSignal.inconclusive;
  }
  final out = stdout.trim();
  final combined = '$stdout$stderr';
  if (exitCode == 0 && out.isNotEmpty) {
    return PidofAbsentSignal.present;
  }
  final classified = classifyAdbFailure(combined);
  if (classified.kind != 'unknown') {
    return PidofAbsentSignal.transportFailure;
  }
  if (out.isEmpty && (exitCode == 0 || exitCode == 1)) {
    if (stderr.trim().isNotEmpty) {
      return PidofAbsentSignal.inconclusive;
    }
    return PidofAbsentSignal.absent;
  }
  return PidofAbsentSignal.inconclusive;
}

final class DeviceShellHealth {
  const DeviceShellHealth({
    required this.ok,
    this.message,
    this.failureKind,
  });

  final bool ok;
  final String? message;
  final String? failureKind;
}

Future<DeviceShellHealth> probeDeviceShellHealth({
  required String adbPath,
  required String deviceSerial,
  AdbArgvRunner? runAdb,
  DevSessionTeardownBudget? budget,
}) async {
  final runner = runAdb ?? defaultAdbArgvRunner;
  try {
    final r = budget == null
        ? await runner(adbPath, adbShellSentinelArgs(serial: deviceSerial))
        : await budget.run(
            () => runner(adbPath, adbShellSentinelArgs(serial: deviceSerial)),
            cap: const Duration(seconds: 5),
          );
    final out = '${r.stdout}'.trim();
    final combined = '${r.stdout}${r.stderr}'.trim();
    if (r.exitCode == 0 && out.contains(adbShellSentinelToken)) {
      return const DeviceShellHealth(ok: true);
    }
    if (r.exitCode != 0) {
      final f = classifyAdbFailure(combined);
      return DeviceShellHealth(
        ok: false,
        failureKind: f.kind,
        message: combined.isEmpty ? 'adb shell sentinel failed' : f.message,
      );
    }
    return const DeviceShellHealth(
      ok: false,
      failureKind: 'unknown',
      message: 'shell sentinel echo mismatch',
    );
  } on TimeoutException {
    return const DeviceShellHealth(
      ok: false,
      failureKind: 'unknown',
      message: 'adb shell sentinel timed out',
    );
  } on DevSessionTeardownBudgetExhausted {
    return const DeviceShellHealth(
      ok: false,
      failureKind: 'unknown',
      message: 'teardown budget exhausted before shell sentinel',
    );
  } on Object catch (e) {
    return DeviceShellHealth(
      ok: false,
      failureKind: 'unknown',
      message: e.toString(),
    );
  }
}

final class PidofWaitAction {
  const PidofWaitAction({
    required this.attempted,
    required this.absentObserved,
    required this.proven,
    this.lastPidOutput,
    this.timedOut = false,
    this.adbFailed = false,
    this.inconclusive = false,
    this.deviceShellVerified = false,
    this.message,
  });

  final bool attempted;
  final bool absentObserved;
  final bool proven;
  final String? lastPidOutput;
  final bool timedOut;
  final bool adbFailed;
  final bool inconclusive;
  final bool deviceShellVerified;
  final String? message;
}

typedef AdbArgvRunner =
    Future<ProcessResult> Function(String adbPath, List<String> args);

typedef SessionTeardownWriter = Future<void> Function(
  String projectPath,
  DevSessionTeardownReport report, {
  SessionTeardownIdentity? identity,
});

/// Bounded adb child: kill the process when [timeout] elapses (default runner).
Future<ProcessResult> runAdbBounded(
  String adbPath,
  List<String> args, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final process = await Process.start(adbPath, args);
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  try {
    final exitCode = await process.exitCode.timeout(timeout);
    return ProcessResult(
      process.pid,
      exitCode,
      await stdoutFuture,
      await stderrFuture,
    );
  } on TimeoutException {
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    rethrow;
  }
}

AdbArgvRunner get defaultAdbArgvRunner => runAdbBounded;

/// Drops a session-owned `adb forward` mapping (best effort).
/// Returns whether `adb forward --remove` was invoked (not whether it succeeded).
Future<bool> releaseDevLaunchOwnedForward({
  required String adbPath,
  required int hostLocalPort,
  String? deviceId,
  AdbArgvRunner? runAdb,
}) async {
  if (hostLocalPort <= 0 || adbPath.isEmpty) return false;
  final runner = runAdb ?? defaultAdbArgvRunner;
  try {
    await runner(
      adbPath,
      adbForwardRemoveArgs(hostPort: hostLocalPort, serial: deviceId),
    );
    return true;
  } on Object {
    return false;
  }
}

typedef ForwardListFetcher =
    Future<ForwardListAction> Function(String adbPath, String? serial);

Future<ForwardListAction> listAdbForwards({
  required String adbPath,
  String? serial,
  AdbArgvRunner? runAdb,
  DevSessionTeardownBudget? budget,
}) async {
  final runner = runAdb ?? defaultAdbArgvRunner;
  try {
    final r = budget == null
        ? await runner(adbPath, adbForwardListArgs(serial: serial))
        : await budget.run(
            () => runner(adbPath, adbForwardListArgs(serial: serial)),
            cap: const Duration(seconds: 5),
          );
    if (r.exitCode != 0) {
      return ForwardListAction(
        ok: false,
        adbExitCode: r.exitCode,
        message: '${r.stdout}${r.stderr}'.trim(),
      );
    }
    return ForwardListAction(
      ok: true,
      entries: parseAdbForwardList('${r.stdout}'),
      adbExitCode: 0,
    );
  } on TimeoutException {
    return const ForwardListAction(
      ok: false,
      timedOut: true,
      message: 'adb forward --list timed out',
    );
  } on DevSessionTeardownBudgetExhausted {
    return const ForwardListAction(
      ok: false,
      message: 'teardown budget exhausted before forward --list',
    );
  } on Object catch (e) {
    return ForwardListAction(ok: false, message: e.toString());
  }
}

Future<ForwardReleaseAction> releaseSessionCreatedForward(
  DevSessionCreatedForward forward, {
  required String adbPath,
  AdbArgvRunner? runAdb,
  ForwardListFetcher? listForwards,
  DevSessionTeardownBudget? budget,
}) async {
  if (forward.hostLocalPort <= 0 || forward.deviceRemotePort <= 0) {
    return const ForwardReleaseAction(
      attempted: false,
      removed: false,
      message: 'invalid forward record',
    );
  }
  final lister =
      listForwards ??
      (adb, serial) => listAdbForwards(
        adbPath: adb,
        serial: serial,
        runAdb: runAdb,
        budget: budget,
      );
  final runner = runAdb ?? defaultAdbArgvRunner;

  final listed = await lister(adbPath, forward.deviceSerial);
  if (!listed.ok) {
    return ForwardReleaseAction(
      attempted: false,
      removed: false,
      listFailed: true,
      message: listed.message ?? 'forward --list failed',
    );
  }
  final entries = listed.entries;
  final match = entries.where(
    (e) =>
        e.serial == forward.deviceSerial &&
        e.hostLocalPort == forward.hostLocalPort,
  );
  if (match.isEmpty) {
    return const ForwardReleaseAction(
      attempted: false,
      removed: false,
      alreadyAbsent: true,
    );
  }
  final live = match.first;
  if (live.deviceRemotePort != forward.deviceRemotePort) {
    return ForwardReleaseAction(
      attempted: false,
      removed: false,
      refusedConcurrencyMismatch: true,
      message:
          'host tcp:${forward.hostLocalPort} now maps to '
          'tcp:${live.deviceRemotePort}, expected '
          'tcp:${forward.deviceRemotePort} — not removing',
    );
  }
  final args = adbForwardRemoveArgs(
    hostPort: forward.hostLocalPort,
    serial: forward.deviceSerial,
  );
  try {
    final r = budget == null
        ? await runner(adbPath, args)
        : await budget.run(
            () => runner(adbPath, args),
            cap: const Duration(seconds: 5),
          );
    if (r.exitCode == 0) {
      return const ForwardReleaseAction(
        attempted: true,
        removed: true,
        adbExitCode: 0,
      );
    }
    final combined = '${r.stdout}${r.stderr}'.trim();
    return ForwardReleaseAction(
      attempted: true,
      removed: false,
      adbExitCode: r.exitCode,
      message: combined.isEmpty ? 'adb forward --remove failed' : combined,
    );
  } on TimeoutException {
    return const ForwardReleaseAction(
      attempted: true,
      removed: false,
      message: 'adb forward --remove timed out',
    );
  } on DevSessionTeardownBudgetExhausted {
    return const ForwardReleaseAction(
      attempted: false,
      removed: false,
      message: 'teardown budget exhausted before forward --remove',
    );
  } on Object catch (e) {
    return ForwardReleaseAction(
      attempted: true,
      removed: false,
      message: e.toString(),
    );
  }
}

Future<ForceStopAction> forceStopLaunchedPackage({
  required String adbPath,
  required String deviceSerial,
  required String packageName,
  AdbArgvRunner? runAdb,
  DevSessionTeardownBudget? budget,
}) async {
  final runner = runAdb ?? defaultAdbArgvRunner;
  final args = adbForceStopArgs(packageName, serial: deviceSerial);
  try {
    final r = budget == null
        ? await runner(adbPath, args)
        : await budget.run(
            () => runner(adbPath, args),
            cap: const Duration(seconds: 5),
          );
    if (r.exitCode == 0) {
      return const ForceStopAction(
        attempted: true,
        commandOk: true,
        adbExitCode: 0,
      );
    }
    return ForceStopAction(
      attempted: true,
      commandOk: false,
      adbExitCode: r.exitCode,
      message: '${r.stdout}${r.stderr}'.trim(),
    );
  } on TimeoutException {
    return const ForceStopAction(
      attempted: true,
      commandOk: false,
      timedOut: true,
      message: 'am force-stop timed out',
    );
  } on DevSessionTeardownBudgetExhausted {
    return const ForceStopAction(
      attempted: false,
      commandOk: false,
      message: 'teardown budget exhausted before force-stop',
    );
  } on Object catch (e) {
    return ForceStopAction(
      attempted: true,
      commandOk: false,
      message: e.toString(),
    );
  }
}

Future<PidofWaitAction> waitDevicePackageAbsent({
  required String adbPath,
  required String deviceSerial,
  required String packageName,
  Duration timeout = const Duration(seconds: 8),
  Duration pollInterval = const Duration(milliseconds: 200),
  AdbArgvRunner? runAdb,
  DevSessionTeardownBudget? budget,
}) async {
  final shell = await probeDeviceShellHealth(
    adbPath: adbPath,
    deviceSerial: deviceSerial,
    runAdb: runAdb,
    budget: budget,
  );
  if (!shell.ok) {
    final transport = shell.failureKind != null && shell.failureKind != 'unknown';
    return PidofWaitAction(
      attempted: true,
      absentObserved: false,
      proven: false,
      adbFailed: transport,
      inconclusive: !transport,
      message: shell.message,
    );
  }

  final runner = runAdb ?? defaultAdbArgvRunner;
  final deadline = DateTime.now().add(timeout);
  String? lastOut;
  while (true) {
    ProcessResult r;
    try {
      r = budget == null
          ? await runner(adbPath, [
              ...adbSerialArgs(deviceSerial),
              'shell',
              'pidof',
              packageName,
            ])
          : await budget.run(
              () => runner(adbPath, [
                ...adbSerialArgs(deviceSerial),
                'shell',
                'pidof',
                packageName,
              ]),
              cap: const Duration(seconds: 5),
            );
    } on TimeoutException {
      return const PidofWaitAction(
        attempted: true,
        absentObserved: false,
        proven: false,
        adbFailed: true,
        deviceShellVerified: true,
        message: 'pidof adb call timed out',
      );
    } on DevSessionTeardownBudgetExhausted {
      return const PidofWaitAction(
        attempted: true,
        absentObserved: false,
        proven: false,
        adbFailed: true,
        deviceShellVerified: true,
        message: 'teardown budget exhausted during pidof',
        timedOut: true,
      );
    }
    final signal = interpretPidofAbsentProbe(
      exitCode: r.exitCode,
      stdout: r.stdout as String,
      stderr: r.stderr as String,
      deviceShellHealthy: true,
    );
    if (signal == PidofAbsentSignal.absent) {
      return const PidofWaitAction(
        attempted: true,
        absentObserved: true,
        proven: false,
        deviceShellVerified: true,
      );
    }
    if (signal == PidofAbsentSignal.transportFailure) {
      final msg = '${r.stdout}${r.stderr}'.trim();
      return PidofWaitAction(
        attempted: true,
        absentObserved: false,
        proven: false,
        adbFailed: true,
        deviceShellVerified: true,
        message: msg.isEmpty ? 'pidof transport failure' : msg,
      );
    }
    if (signal == PidofAbsentSignal.inconclusive) {
      final msg = '${r.stdout}${r.stderr}'.trim();
      return PidofWaitAction(
        attempted: true,
        absentObserved: false,
        proven: false,
        inconclusive: true,
        deviceShellVerified: true,
        message: msg.isEmpty
            ? 'pidof exit ${r.exitCode} not attributable after shell sentinel'
            : msg,
      );
    }
    lastOut = '${r.stdout}'.trim();
    final timedOut = budget != null
        ? budget.elapsed >= timeout || budget.exhausted
        : DateTime.now().isAfter(deadline);
    if (timedOut) {
      return PidofWaitAction(
        attempted: true,
        absentObserved: false,
        proven: false,
        lastPidOutput: lastOut,
        timedOut: true,
        deviceShellVerified: true,
      );
    }
    await Future<void>.delayed(pollInterval);
  }
}

/// Quit-path device absence: `app.stop` alone is insufficient on attach.
bool deviceAbsentAfterQuitActions({required PidofWaitAction? pidofWait}) =>
    pidofWait?.absentObserved == true;

final class DevSessionTeardownReport {
  const DevSessionTeardownReport({
    this.appStop,
    this.pidofWait,
    this.forceStop,
    this.forward,
    this.attachDaemon,
    this.attachHost,
    this.budgetExhausted = false,
  });

  final AppStopAction? appStop;
  final PidofWaitAction? pidofWait;
  final ForceStopAction? forceStop;
  final ForwardReleaseAction? forward;
  final DaemonDisposeReport? attachDaemon;
  final AttachHostProcessIdentity? attachHost;
  final bool budgetExhausted;

  bool get provenForwardRemoved => false;
  bool get provenDeviceAppAbsent => false;
  bool get provenPhysicalSettlement => false;

  /// In-session cleanup actions (not consumer settlement proof).
  bool get actionsSucceeded {
    if (budgetExhausted) return false;
    final ad = attachDaemon;
    if (ad != null && !ad.processExited) return false;
    final fwd = forward;
    if (fwd != null) {
      if (fwd.listFailed) return false;
      if (fwd.attempted && !fwd.removed && !fwd.alreadyAbsent) return false;
      if (fwd.refusedConcurrencyMismatch) return false;
    }
    if (appStop != null ||
        pidofWait != null ||
        forceStop != null) {
      if (pidofWait != null || forceStop != null) {
        return deviceAbsentAfterQuitActions(pidofWait: pidofWait);
      }
    }
    return true;
  }

  Map<String, Object?> toJson() => {
    'actionsSucceeded': actionsSucceeded,
    'provenForwardRemoved': provenForwardRemoved,
    'provenDeviceAppAbsent': provenDeviceAppAbsent,
    'provenPhysicalSettlement': provenPhysicalSettlement,
    'budgetExhausted': budgetExhausted,
    if (appStop != null)
      'appStop': {
        'rpcOk': appStop!.rpcOk,
        'timedOut': appStop!.timedOut,
        'stopEventSeen': appStop!.stopEventSeen,
        'ms': appStop!.duration.inMilliseconds,
        if (appStop!.errorText != null) 'error': appStop!.errorText,
        if (appStop!.resultSummary != null) 'result': appStop!.resultSummary,
      },
    if (forceStop != null)
      'forceStop': {
        'attempted': forceStop!.attempted,
        'commandOk': forceStop!.commandOk,
        'timedOut': forceStop!.timedOut,
        if (forceStop!.message != null) 'message': forceStop!.message,
      },
    if (pidofWait != null)
      'pidofWait': {
        'attempted': pidofWait!.attempted,
        'absentObserved': pidofWait!.absentObserved,
        'timedOut': pidofWait!.timedOut,
        'adbFailed': pidofWait!.adbFailed,
        'inconclusive': pidofWait!.inconclusive,
        'deviceShellVerified': pidofWait!.deviceShellVerified,
        if (pidofWait!.lastPidOutput != null) 'lastPid': pidofWait!.lastPidOutput,
        if (pidofWait!.message != null) 'message': pidofWait!.message,
      },
    if (forward != null)
      'forward': {
        'attempted': forward!.attempted,
        'removed': forward!.removed,
        'alreadyAbsent': forward!.alreadyAbsent,
        'refusedMismatch': forward!.refusedConcurrencyMismatch,
        'listFailed': forward!.listFailed,
        if (forward!.message != null) 'message': forward!.message,
      },
    if (attachDaemon != null)
      'attachDaemon': {
        'shutdownAttempted': attachDaemon!.shutdownAttempted,
        'shutdownAcknowledged': attachDaemon!.shutdownAcknowledged,
        'processExited': attachDaemon!.processExited,
        'killedAsBackstop': attachDaemon!.killedAsBackstop,
        if (attachDaemon!.message != null) 'message': attachDaemon!.message,
      },
    if (attachHost != null)
      'attachHost': {
        'attachPid': attachHost!.attachPid,
        'spawnEpochUtc': attachHost!.spawnEpoch.toUtc().toIso8601String(),
        'note': 'diagnostic only — not OS start-time identity',
      },
  };
}

Future<ForwardReleaseAction> releaseSessionOwnedResources(
  DevSessionResourceOwnership ownership, {
  DevSessionTeardownBudget? budget,
}) async {
  final forward = ownership.vmServiceForward;
  if (forward == null) {
    return const ForwardReleaseAction(
      attempted: false,
      removed: false,
      message: 'no forward record',
    );
  }
  return releaseSessionCreatedForward(
    forward,
    adbPath: ownership.adbPath,
    budget: budget,
    runAdb: ownership.runAdb,
  );
}

const sessionTeardownFileName = 'session-teardown.json';

/// Matches `.flutter_mcp/runner-session.json` at teardown write time.
final class SessionTeardownIdentity {
  const SessionTeardownIdentity({
    required this.runnerPid,
    required this.controlPort,
    required this.sessionStartedAtUtc,
  });

  final int runnerPid;
  final int controlPort;
  final String sessionStartedAtUtc;

  Map<String, Object?> toJson() => {
    'runnerPid': runnerPid,
    'controlPort': controlPort,
    'sessionStartedAtUtc': sessionStartedAtUtc,
  };
}

Future<void> writeSessionTeardownFile(
  String projectPath,
  DevSessionTeardownReport report, {
  SessionTeardownIdentity? identity,
}) async {
  final dir = Directory('$projectPath/.flutter_mcp');
  await dir.create(recursive: true);
  final file = File('${dir.path}/$sessionTeardownFileName');
  final payload = <String, Object?>{
    'schema': 1,
    if (identity != null) 'identity': identity.toJson(),
    ...report.toJson(),
  };
  await file.writeAsString('${jsonEncode(payload)}\n');
}

Map<String, Object?>? readSessionTeardownFile(String projectPath) {
  final file = File('$projectPath/.flutter_mcp/$sessionTeardownFileName');
  if (!file.existsSync()) return null;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return null;
    return Map<String, Object?>.from(decoded);
  } on Object {
    return null;
  }
}

/// Live [readRunnerSessionFile] snapshot taken when cooperative stop begins.
final class SessionTeardownStopExpectation {
  const SessionTeardownStopExpectation({
    required this.runnerPid,
    required this.controlPort,
    required this.sessionStartedAtUtc,
  });

  /// Discovery **owner** pid (not harness spawn pid when they differ).
  final int runnerPid;
  final int controlPort;
  final String sessionStartedAtUtc;
}

bool _identityMatchesSidecar(
  Object? id,
  SessionTeardownStopExpectation expected,
) {
  if (id is! Map) return false;
  final runnerPid = id['runnerPid'];
  final controlPort = id['controlPort'];
  final startedAt = id['sessionStartedAtUtc'];
  if (runnerPid is! int ||
      controlPort is! int ||
      startedAt is! String) {
    return false;
  }
  return runnerPid == expected.runnerPid &&
      controlPort == expected.controlPort &&
      startedAt == expected.sessionStartedAtUtc;
}

/// Reads teardown receipt only when [expectedDiscovery] matches sidecar identity.
///
/// Missing/malformed `identity`, stale session, or spawn≠owner without a live
/// discovery snapshot at stop start all yield `null` (fail-closed).
Map<String, Object?>? readSessionTeardownForOwningStop({
  required String projectPath,
  required SessionTeardownStopExpectation? expectedDiscovery,
}) {
  if (expectedDiscovery == null) return null;
  final raw = readSessionTeardownFile(projectPath);
  if (raw == null) return null;
  final id = raw['identity'];
  if (!_identityMatchesSidecar(id, expectedDiscovery)) return null;
  return raw;
}

Future<void> clearSessionTeardownFile(String projectPath) async {
  final file = File('$projectPath/.flutter_mcp/$sessionTeardownFileName');
  if (file.existsSync()) {
    await file.delete();
  }
}
