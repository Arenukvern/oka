/// Physical teardown helpers for `oka dev android` (SDK-owned resources only).
///
/// Forward removal authority comes solely from [DevSessionCreatedForward]
/// recorded at `adb forward` creation time (serial + local + remote). Listing
/// or remote-port coincidence alone never authorizes removal. No `--remove-all`.
///
/// [DevSessionTeardownReport.proven*] fields stay false — consumers observe
/// settlement; this layer only records action outcomes.
library;

import 'dart:async';
import 'dart:io';

import 'adb_tool.dart';
import 'daemon_adapter.dart';

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

/// Attach host child captured at [spawnAttachDaemon] (before cooperative stop).
final class AttachHostProcessIdentity {
  const AttachHostProcessIdentity({
    required this.pid,
    required this.startedAt,
  });

  final int pid;
  final DateTime startedAt;
}

AttachHostProcessIdentity? attachHostIdentityFor(DaemonTransport transport) {
  if (transport is ProcessDaemonTransport) {
    return AttachHostProcessIdentity(
      pid: transport.pid,
      startedAt: transport.startedAt,
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
  });

  final String adbPath;
  final DevSessionCreatedForward? vmServiceForward;
  final DevSessionLaunchIdentity? launchIdentity;
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

/// Parses `adb forward --list` output (ignores banner lines).
List<AdbForwardListEntry> parseAdbForwardList(String output) {
  final entries = <AdbForwardListEntry>[];
  final lineRe = RegExp(
    r'^(\S+)\s+tcp:(\d+)\s+tcp:(\d+)\s*$',
  );
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

/// Result of removing one [DevSessionCreatedForward].
final class ForwardReleaseAction {
  const ForwardReleaseAction({
    required this.attempted,
    required this.removed,
    this.alreadyAbsent = false,
    this.refusedConcurrencyMismatch = false,
    this.adbExitCode,
    this.message,
  });

  final bool attempted;
  final bool removed;
  final bool alreadyAbsent;
  final bool refusedConcurrencyMismatch;
  final int? adbExitCode;
  final String? message;
}

/// `app.stop` RPC outcome on quit (not used on detach).
final class AppStopAction {
  const AppStopAction({
    required this.rpcOk,
    required this.duration,
    this.errorText,
    this.resultSummary,
    this.timedOut = false,
  });

  final bool rpcOk;
  final Duration duration;
  final String? errorText;
  final String? resultSummary;
  final bool timedOut;
}

/// Bounded `pidof` poll after quit when [DevSessionLaunchIdentity] is set.
final class PidofWaitAction {
  const PidofWaitAction({
    required this.attempted,
    required this.absentObserved,
    required this.proven,
    this.lastPidOutput,
    this.timedOut = false,
  });

  final bool attempted;
  final bool absentObserved;
  final bool proven;
  final String? lastPidOutput;
  final bool timedOut;
}

typedef AdbArgvRunner =
    Future<ProcessResult> Function(String adbPath, List<String> args);

typedef ForwardListFetcher =
    Future<List<AdbForwardListEntry>> Function(String adbPath, String? serial);

Future<List<AdbForwardListEntry>> _defaultListForwards(
  String adbPath,
  String? serial,
) async {
  final r = await Process.run(adbPath, adbForwardListArgs(serial: serial));
  if (r.exitCode != 0) return const [];
  return parseAdbForwardList('${r.stdout}');
}

/// Removes [forward] only when `--list` still shows the same serial/local/remote.
Future<ForwardReleaseAction> releaseSessionCreatedForward(
  DevSessionCreatedForward forward, {
  required String adbPath,
  AdbArgvRunner? runAdb,
  ForwardListFetcher? listForwards,
}) async {
  if (forward.hostLocalPort <= 0 || forward.deviceRemotePort <= 0) {
    return const ForwardReleaseAction(
      attempted: false,
      removed: false,
      message: 'invalid forward record',
    );
  }
  final lister =
      listForwards ?? _defaultListForwards;
  final runner = runAdb ?? Process.run;

  final entries = await lister(adbPath, forward.deviceSerial);
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
    final r = await runner(adbPath, args);
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
  } on Object catch (e) {
    return ForwardReleaseAction(
      attempted: true,
      removed: false,
      message: e.toString(),
    );
  }
}

Future<PidofWaitAction> waitDevicePackageAbsent({
  required String adbPath,
  required String deviceSerial,
  required String packageName,
  Duration timeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 200),
  AdbArgvRunner? runAdb,
}) async {
  final runner = runAdb ?? Process.run;
  final deadline = DateTime.now().add(timeout);
  String? lastOut;
  while (true) {
    final r = await runner(adbPath, [
      ...adbSerialArgs(deviceSerial),
      'shell',
      'pidof',
      packageName,
    ]);
    lastOut = (r.stdout as String).trim();
    if (lastOut.isEmpty) {
      return const PidofWaitAction(
        attempted: true,
        absentObserved: true,
        proven: false,
      );
    }
    if (DateTime.now().isAfter(deadline)) {
      return PidofWaitAction(
        attempted: true,
        absentObserved: false,
        proven: false,
        lastPidOutput: lastOut,
        timedOut: true,
      );
    }
    await Future<void>.delayed(pollInterval);
  }
}

/// Aggregated teardown actions for one [DevSession.run].
final class DevSessionTeardownReport {
  const DevSessionTeardownReport({
    this.appStop,
    this.pidofWait,
    this.forward,
    this.attachDaemon,
    this.attachHost,
  });

  final AppStopAction? appStop;
  final PidofWaitAction? pidofWait;
  final ForwardReleaseAction? forward;
  final DaemonDisposeReport? attachDaemon;
  final AttachHostProcessIdentity? attachHost;

  /// Always false here — settlement is consumer-observed only.
  bool get provenForwardRemoved => false;

  bool get provenDeviceAppAbsent => false;

  bool get provenPhysicalSettlement => false;

  Map<String, Object?> toJson() => {
    'provenForwardRemoved': provenForwardRemoved,
    'provenDeviceAppAbsent': provenDeviceAppAbsent,
    'provenPhysicalSettlement': provenPhysicalSettlement,
    if (appStop != null)
      'appStop': {
        'rpcOk': appStop!.rpcOk,
        'timedOut': appStop!.timedOut,
        'ms': appStop!.duration.inMilliseconds,
        if (appStop!.errorText != null) 'error': appStop!.errorText,
        if (appStop!.resultSummary != null) 'result': appStop!.resultSummary,
      },
    if (pidofWait != null)
      'pidofWait': {
        'attempted': pidofWait!.attempted,
        'absentObserved': pidofWait!.absentObserved,
        'timedOut': pidofWait!.timedOut,
        if (pidofWait!.lastPidOutput != null) 'lastPid': pidofWait!.lastPidOutput,
      },
    if (forward != null)
      'forward': {
        'attempted': forward!.attempted,
        'removed': forward!.removed,
        'alreadyAbsent': forward!.alreadyAbsent,
        'refusedMismatch': forward!.refusedConcurrencyMismatch,
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
        'pid': attachHost!.pid,
        'startedAt': attachHost!.startedAt.toUtc().toIso8601String(),
      },
  };
}

Future<ForwardReleaseAction> releaseSessionOwnedResources(
  DevSessionResourceOwnership ownership,
) async {
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
  );
}
