import 'dart:io';

/// First character of `State` from `/proc/<pid>/stat` (e.g. R, S, Z).
String? linuxProcStateChar(int pid) {
  if (!Platform.isLinux || pid <= 0) return null;
  try {
    final stat = File('/proc/$pid/stat').readAsStringSync();
    final close = stat.lastIndexOf(')');
    if (close < 0 || close + 2 >= stat.length) return null;
    return stat.substring(close + 2, close + 3);
  } on Object {
    return null;
  }
}

/// Brief label for drain diagnostics (state + comm).
String? linuxProcDiagLabel(int pid) {
  if (!Platform.isLinux || pid <= 0) return null;
  try {
    final stat = File('/proc/$pid/stat').readAsStringSync();
    final open = stat.indexOf('(');
    final close = stat.lastIndexOf(')');
    final comm = open >= 0 && close > open
        ? stat.substring(open + 1, close)
        : '?';
    final state = close >= 0 && close + 2 < stat.length
        ? stat.substring(close + 2, close + 3)
        : '?';
    return '$pid:$state:$comm';
  } on Object {
    return '$pid:?:?';
  }
}
