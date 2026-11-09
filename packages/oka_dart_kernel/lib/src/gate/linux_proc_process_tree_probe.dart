import 'dart:io';

import 'package:oka_core/oka_core.dart';

/// Linux process table via `/proc` — no `ps` subprocess (avoids subreaper adoptees).
Map<int, int> buildLinuxProcParentMap({Duration? wallClockCap}) {
  final parentOf = <int, int>{};
  if (!Platform.isLinux) return parentOf;
  final cap = wallClockCap ?? const Duration(seconds: 3);
  final scanStarted = DateTime.now();
  try {
    for (final ent in Directory('/proc').listSync(followLinks: false)) {
      if (DateTime.now().difference(scanStarted) > cap) break;
      final name = ent.path.split('/').last;
      final pid = int.tryParse(name);
      if (pid == null || pid <= 0) continue;
      try {
        final stat = File('/proc/$pid/stat').readAsStringSync();
        final close = stat.lastIndexOf(')');
        if (close < 0) continue;
        final fields = stat.substring(close + 2).trim().split(RegExp(r'\s+'));
        if (fields.length < 2) continue;
        final ppid = int.tryParse(fields[1]);
        if (ppid == null) continue;
        parentOf[pid] = ppid;
      } on Object {
        continue;
      }
    }
  } on Object {
    return parentOf;
  }
  return parentOf;
}

final class LinuxProcProcessTreeProbe implements ProcessTreeProbe {
  const LinuxProcProcessTreeProbe();

  @override
  Future<ProcessTree?> enumerate(int rootPid) async {
    if (rootPid <= 0) return ProcessTree(rootPid: rootPid, parentOf: const {});
    final parentOf = buildLinuxProcParentMap();
    if (parentOf.isEmpty) return null;
    return ProcessTree(rootPid: rootPid, parentOf: parentOf);
  }
}
