import 'dart:io';

/// One `ps` row: pid, ppid, pgid, stat.
typedef PsGroupRow = (int pid, int ppid, int pgid, String stat);

Future<List<PsGroupRow>?> readProcessGroupRows() async {
  try {
    final result = await Process.run('ps', [
      '-eo',
      'pid=,ppid=,pgid=,stat=',
    ]).timeout(const Duration(seconds: 2));
    if (result.exitCode != 0) return null;
    final output = result.stdout as String;
    final rows = <PsGroupRow>[];
    for (final line in output.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length != 4 || parts[3].startsWith('Z')) continue;
      final values = [for (final value in parts.take(3)) int.tryParse(value)];
      if (values.any((value) => value == null)) continue;
      rows.add((values[0]!, values[1]!, values[2]!, parts[3]));
    }
    return rows;
  } on Object {
    return null;
  }
}

Future<bool?> pidAlive(int pid) async {
  try {
    final result = await Process.run('kill', [
      '-0',
      '$pid',
    ]).timeout(const Duration(seconds: 2));
    return result.exitCode == 0;
  } on Object {
    return null;
  }
}
