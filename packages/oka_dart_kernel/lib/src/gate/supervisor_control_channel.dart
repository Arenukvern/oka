import 'dart:io';

import 'package:path/path.dart' as p;

import 'supervisor_session_protocol.dart';

/// Environment keys visible only to the dedicated supervisor process — never
/// forwarded to the workload (see [sanitizeWorkloadEnvironment]).
const kSupervisorNonceEnv = 'OKA_DEV_SUPERVISOR_NONCE';
const kSupervisorAckPathEnv = 'OKA_DEV_SUPERVISOR_ACK_PATH';

/// Legacy nonce name; stripped from workload if ever inherited.
const kLegacySessionNonceEnv = 'OKA_DEV_SESSION_NONCE';

const _workloadEnvDenylist = {
  kSupervisorNonceEnv,
  kLegacySessionNonceEnv,
  kSupervisorAckPathEnv,
};

/// Creates an append-only control log (mode 0600) for supervisor → session acks.
///
/// The path is passed only in the supervisor environment ([kSupervisorAckPathEnv]).
/// Workload children never receive the path, nonce, or any handle to this sink
/// ([sanitizeWorkloadEnvironment]). Workload stdout/stderr are forwarded as raw
/// bytes only — never parsed as control frames.
Future<File> createSupervisorControlSink() async {
  final dir = await Directory.systemTemp.createTemp('oka_supervisor_ctl');
  final file = File(p.join(dir.path, 'control.log'));
  await file.create();
  try {
    await Process.run('chmod', ['0600', file.path]);
  } on Object {
    // Best effort; session still owns the path.
  }
  return file;
}

Map<String, String> sanitizeWorkloadEnvironment(Map<String, String> supervisorEnv) => {
      for (final e in supervisorEnv.entries)
        if (!_workloadEnvDenylist.contains(e.key)) e.key: e.value,
    };

/// Parses new control-log lines (not workload-forwarded streams).
SupervisorControlUpdate parseSupervisorControlLines(Iterable<String> lines) {
  SupervisorDrainAck? ack;
  int? workloadPid;
  int? supervisorExit;
  int? workloadExit;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final wp = RegExp(r'^oka_dev_workload_pid=(\d+)$').firstMatch(line);
    if (wp != null) {
      workloadPid = int.parse(wp.group(1)!);
      continue;
    }
    final parsedAck = parseSupervisorDrainAck(line);
    if (parsedAck != null) {
      ack = parsedAck;
      continue;
    }
    final shut = RegExp(
      r'^oka_dev_supervisor_shutdown supervisor_exit=(-?\d+) workload_exit=(-?\d+)$',
    ).firstMatch(line);
    if (shut != null) {
      supervisorExit = int.parse(shut.group(1)!);
      workloadExit = int.parse(shut.group(2)!);
    }
  }
  return SupervisorControlUpdate(
    drainAck: ack,
    workloadPid: workloadPid,
    supervisorExitCode: supervisorExit,
    workloadExitCode: workloadExit,
  );
}

Future<void> appendSupervisorControlLine(String line) async {
  final path = Platform.environment[kSupervisorAckPathEnv]?.trim();
  if (path == null || path.isEmpty) return;
  final file = File(path);
  await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
}

final class SupervisorControlUpdate {
  const SupervisorControlUpdate({
    this.drainAck,
    this.workloadPid,
    this.supervisorExitCode,
    this.workloadExitCode,
  });

  final SupervisorDrainAck? drainAck;
  final int? workloadPid;
  final int? supervisorExitCode;
  final int? workloadExitCode;
}
