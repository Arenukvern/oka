String displayCacheArgv(List<String> argv) => argv
    .map(
      (value) => RegExp(r'^[a-zA-Z0-9_./:=,-]+$').hasMatch(value)
          ? value
          : "'${value.replaceAll("'", r"'\''")}'",
    )
    .join(' ');

String formatCacheBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = -1;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
}
