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

/// Supervisor wrapper inherits the parent environment plus session keys.
Map<String, String> supervisorSessionEnvironment({
  required String sessionNonce,
  required String controlPath,
  String? sessionCwd,
  Map<String, String>? extra,
}) {
  final env = Map<String, String>.from(Platform.environment);
  env.remove(kLegacySessionNonceEnv);
  env[kSupervisorNonceEnv] = sessionNonce;
  env[kSupervisorAckPathEnv] = controlPath;
  if (sessionCwd != null && sessionCwd.isNotEmpty) {
    env['OKA_DEV_SESSION_CWD'] = sessionCwd;
  }
  if (extra != null) {
    env.addAll(extra);
  }
  return env;
}

/// Complete environment map for workload children — no parent merge at spawn.
Map<String, String> workloadProcessEnvironment([Map<String, String>? supervisorView]) {
  final base = supervisorView ?? Platform.environment;
  return sanitizeWorkloadEnvironment(Map<String, String>.from(base));
}

Map<String, String> sanitizeWorkloadEnvironment(Map<String, String> supervisorEnv) => {
      for (final e in supervisorEnv.entries)
        if (!_workloadEnvDenylist.contains(e.key)) e.key: e.value,
    };

/// Creates an append-only control log under a private temp directory (0700).
///
/// The path is passed only in the supervisor environment ([kSupervisorAckPathEnv]).
/// [sanitizeWorkloadEnvironment] removes the path, nonce, and legacy session
/// nonce from the workload child's environment map (accidental inheritance /
/// forged workload **output** isolation — not a hostile same-UID sandbox).
/// Workload stdout/stderr are forwarded as raw bytes only — never parsed as
/// control frames.
Future<File> createSupervisorControlSink() async {
  final dir = await Directory.systemTemp.createTemp('oka_supervisor_ctl_');
  if (Platform.isLinux) {
    final mode = await Process.run('chmod', ['0700', dir.path]);
    if (mode.exitCode != 0) {
      throw StateError('chmod 0700 on control dir failed: ${mode.stderr}');
    }
  }
  final file = File(p.join(dir.path, 'control.log'));
  if (file.existsSync()) {
    throw StateError('control sink already exists: ${file.path}');
  }
  final raf = await file.open(mode: FileMode.writeOnly);
  await raf.close();
  if (Platform.isLinux) {
    final mode = await Process.run('chmod', ['0600', file.path]);
    if (mode.exitCode != 0) {
      throw StateError('chmod 0600 on control sink failed: ${mode.stderr}');
    }
  }
  return file;
}

/// Parses complete control-log lines (not workload-forwarded streams).
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

/// Opens the control sink once for append-only supervisor writes.
final class SupervisorControlWriter {
  SupervisorControlWriter._(this._raf);

  final RandomAccessFile _raf;

  static Future<SupervisorControlWriter> open() async {
    final path = Platform.environment[kSupervisorAckPathEnv]?.trim();
    if (path == null || path.isEmpty) {
      throw StateError('missing $kSupervisorAckPathEnv');
    }
    final file = File(path);
    final raf = await file.open(mode: FileMode.append);
    return SupervisorControlWriter._(raf);
  }

  Future<void> writeLine(String line) async {
    await _raf.writeString('$line\n');
    await _raf.flush();
  }

  Future<void> close() => _raf.close();
}

SupervisorControlWriter? _writer;

Future<void> ensureSupervisorControlWriter() async {
  _writer ??= await SupervisorControlWriter.open();
}

Future<void> appendSupervisorControlLine(String line) async {
  try {
    await ensureSupervisorControlWriter();
    await _writer!.writeLine(line);
  } on Object {
    // Missing path in tests that skip control; ignore.
  }
}

/// Incremental UTF-8 line splitter for control-log reads.
final class ControlLogLineReader {
  String _partial = '';

  Iterable<String> push(String chunk) {
    final text = '$_partial$chunk';
    final parts = text.split('\n');
    if (text.endsWith('\n')) {
      _partial = '';
      return parts.where((l) => l.isNotEmpty);
    }
    _partial = parts.removeLast();
    return parts.where((l) => l.isNotEmpty);
  }

  Iterable<String> flushPartial() {
    if (_partial.isEmpty) return const [];
    final line = _partial;
    _partial = '';
    return [line];
  }
}

/// Fixture-only reports in workload streams (tests); never used for authority.
Iterable<FixtureEscapedReport> fixtureEscapedReportsFromTranscript(String text) sync* {
  for (final line in text.split('\n')) {
    final esc = parseFixtureEscapedReport(line.trim());
    if (esc != null) yield esc;
  }
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
