/// Single-instance directory lock for long-lived lanes (ADR-0038 §4).
///
/// ## Two dialects, one liveness seam (ADR-0018 / 0038 / 0040)
///
/// | Need | Use |
/// | --- | --- |
/// | Watch→rebuild command lane (optmem, laya) | [DirectoryProcessLock] + `runSupervisedCommandLanes` |
/// | Spawned long-lived service (emulator, uatk serve) | [ProcessLeaseRegistry] + supervisor converge |
///
/// Both use [ProcessLiveness] for "is this pid still us?". Do not invent a
/// third lock spelling in consumers. Do not put this mutex in DFP — it is
/// oka process substrate.
///
/// Creation uses exclusive `mkdir` on POSIX (Dart's [Directory.createSync]
/// is not exclusive when the path already exists).
library;

import 'dart:io';

import 'process_liveness.dart';

/// Directory mutex: create [directory] exclusively; steal when the recorded
/// holder pid is dead. Caller releases on exit.
final class DirectoryProcessLock {
  DirectoryProcessLock(
    this.directory, {
    this.label = 'lane',
    ProcessLiveness? liveness,
  }) : _liveness = liveness ?? const HostProcessLiveness();

  /// Lock directory (created empty; contains `pid` file while held).
  final Directory directory;

  /// Log / receipt label.
  final String label;

  final ProcessLiveness _liveness;

  /// Acquire the lock. Returns `false` when another live holder owns it
  /// (caller should exit 0). Steals stale locks.
  Future<bool> tryAcquire() async {
    Directory(directory.parent.path).createSync(recursive: true);
    if (!_mkdirExclusive(directory)) {
      final holder = holderPid();
      if (holder == pid) {
        return true;
      }
      if (holder != 0 && await _liveness.isAlive(holder)) {
        stderr.writeln('[$label] lane already running (pid $holder)');
        return false;
      }
      stderr.writeln('[$label] stealing stale lock from pid $holder');
      if (directory.existsSync()) directory.deleteSync(recursive: true);
      if (!_mkdirExclusive(directory)) {
        stderr.writeln('[$label] lost race acquiring lock');
        return false;
      }
    }
    File('${directory.path}/pid').writeAsStringSync('pid=$pid\n');
    return true;
  }

  /// Drop the lock directory if present.
  void release() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }

  /// Pid written by the current holder, or 0.
  int holderPid() {
    final f = File('${directory.path}/pid');
    if (!f.existsSync()) return 0;
    final line = f.readAsStringSync().split('\n').firstWhere(
          (l) => l.startsWith('pid='),
          orElse: () => 'pid=0',
        );
    return int.tryParse(line.substring(4)) ?? 0;
  }
}

/// Exclusive directory create. POSIX `mkdir` fails if the path exists;
/// Windows falls back to exists-then-create (narrow race window).
bool _mkdirExclusive(Directory directory) {
  if (Platform.isWindows) {
    if (directory.existsSync()) return false;
    try {
      directory.createSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }
  final result = Process.runSync('mkdir', [directory.path]);
  return result.exitCode == 0;
}
