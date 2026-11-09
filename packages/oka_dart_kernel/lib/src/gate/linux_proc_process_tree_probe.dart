import 'dart:async';
import 'dart:io';

import 'package:oka_core/oka_core.dart';

/// Result of a bounded `/proc` parent-map scan (no `ps` subprocess).
final class LinuxProcParentMapScan {
  const LinuxProcParentMapScan({
    required this.entries,
    required this.complete,
    required this.errors,
    required this.timedOut,
  });

  final Map<int, int> entries;
  final bool complete;
  final List<String> errors;
  final bool timedOut;

  ProcessTree? treeFor(int rootPid) {
    if (!complete) return null;
    if (entries.isEmpty && rootPid <= 0) {
      return ProcessTree(rootPid: rootPid, parentOf: const {});
    }
    if (entries.isEmpty) return null;
    return ProcessTree(rootPid: rootPid, parentOf: entries);
  }
}

enum LinuxProcStatReadOutcome { ok, vanished, error }

final class LinuxProcStatRead {
  const LinuxProcStatRead.ok(this.stat)
      : outcome = LinuxProcStatReadOutcome.ok,
        detail = null;

  const LinuxProcStatRead.vanished()
      : outcome = LinuxProcStatReadOutcome.vanished,
        stat = null,
        detail = null;

  const LinuxProcStatRead.error(this.detail)
      : outcome = LinuxProcStatReadOutcome.error,
        stat = null;

  final LinuxProcStatReadOutcome outcome;
  final String? stat;
  final String? detail;
}

/// Injectable seam for production `/proc` reads (tests hook here).
abstract interface class LinuxProcStatReader {
  Future<List<int>> listProcPids();

  Future<LinuxProcStatRead> readStat(int pid);
}

final class HostLinuxProcStatReader implements LinuxProcStatReader {
  const HostLinuxProcStatReader();

  @override
  Future<List<int>> listProcPids() async {
    if (!Platform.isLinux) return const [];
    final pids = <int>[];
    try {
      for (final ent in Directory('/proc').listSync(followLinks: false)) {
        final name = ent.path.split('/').last;
        final pid = int.tryParse(name);
        if (pid != null && pid > 0) pids.add(pid);
      }
    } on Object {
      return const [];
    }
    return pids;
  }

  @override
  Future<LinuxProcStatRead> readStat(int pid) async {
    if (!Platform.isLinux || pid <= 0) {
      return const LinuxProcStatRead.error('invalid pid');
    }
    try {
      final stat = await File('/proc/$pid/stat').readAsString();
      return LinuxProcStatRead.ok(stat);
    } on FileSystemException catch (e) {
      if (e.osError?.errorCode == 2) {
        return const LinuxProcStatRead.vanished();
      }
      return LinuxProcStatRead.error(
        'pid $pid: ${e.message} (errno ${e.osError?.errorCode})',
      );
    } on Object catch (e) {
      return LinuxProcStatRead.error('pid $pid: $e');
    }
  }
}

/// Parses ppid from `/proc/<pid>/stat` using the last `)` (comm may contain `)`).
int? parseLinuxProcStatPpid(String stat) {
  final close = stat.lastIndexOf(')');
  if (close < 0) return null;
  final fields = stat.substring(close + 2).trim().split(RegExp(r'\s+'));
  if (fields.length < 2) return null;
  return int.tryParse(fields[1]);
}

/// Scans `/proc` for pid→ppid, bounded by [deadline] (monotonic wall clock).
Future<LinuxProcParentMapScan> scanLinuxProcParentMap({
  required DateTime deadline,
  LinuxProcStatReader reader = const HostLinuxProcStatReader(),
}) async {
  final entries = <int, int>{};
  final errors = <String>[];
  var timedOut = false;

  if (!Platform.isLinux) {
    return LinuxProcParentMapScan(
      entries: entries,
      complete: false,
      errors: const ['not linux'],
      timedOut: false,
    );
  }

  List<int> pids;
  try {
    pids = await reader.listProcPids();
  } on Object catch (e) {
    return LinuxProcParentMapScan(
      entries: entries,
      complete: false,
      errors: ['list /proc: $e'],
      timedOut: false,
    );
  }

  if (pids.isEmpty) {
    return LinuxProcParentMapScan(
      entries: entries,
      complete: false,
      errors: const ['list /proc: no pid entries'],
      timedOut: false,
    );
  }

  for (final pid in pids) {
    if (!DateTime.now().isBefore(deadline)) {
      timedOut = true;
      break;
    }
    final read = await reader.readStat(pid);
    switch (read.outcome) {
      case LinuxProcStatReadOutcome.vanished:
        continue;
      case LinuxProcStatReadOutcome.error:
        errors.add(read.detail ?? 'pid $pid: read error');
      case LinuxProcStatReadOutcome.ok:
        final ppid = parseLinuxProcStatPpid(read.stat!);
        if (ppid == null) {
          errors.add('pid $pid: malformed stat');
        } else {
          entries[pid] = ppid;
        }
    }
  }

  if (timedOut && errors.isEmpty) {
    errors.add('scan timed out under deadline');
  }

  final complete = !timedOut && errors.isEmpty && entries.isNotEmpty;
  return LinuxProcParentMapScan(
    entries: entries,
    complete: complete,
    errors: errors,
    timedOut: timedOut,
  );
}

final class LinuxProcProcessTreeProbe implements ProcessTreeProbe {
  const LinuxProcProcessTreeProbe({this.scanBudget});

  /// Wall-clock budget for a single probe (no subprocess).
  final Duration? scanBudget;

  @override
  Future<ProcessTree?> enumerate(int rootPid) async {
    if (rootPid <= 0) {
      return ProcessTree(rootPid: rootPid, parentOf: const {});
    }
    final budget = scanBudget ?? const Duration(seconds: 2);
    final scan = await scanLinuxProcParentMap(
      deadline: DateTime.now().add(budget),
    );
    if (!scan.complete) return null;
    return scan.treeFor(rootPid);
  }
}
