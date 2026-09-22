/// Parses cache age criteria such as `30d`, `12h`, and `45m`.
Duration? parseCacheDuration(String raw) {
  final match = RegExp(r'^(\d+)([dhm])$').firstMatch(raw.trim());
  if (match == null) return null;
  final value = int.tryParse(match.group(1)!);
  if (value == null) return null;
  final unit = switch (match.group(2)) {
    'd' => Duration.microsecondsPerDay,
    'h' => Duration.microsecondsPerHour,
    'm' => Duration.microsecondsPerMinute,
    _ => 0,
  };
  if (unit == 0 || value > 8640000000000000000 ~/ unit) return null;
  return Duration(microseconds: value * unit);
}

/// Parses binary cache size criteria while preserving legacy spellings.
int? parseCacheSize(String raw) {
  final match = RegExp(
    r'^(\d+)(B|K|KB|KIB|M|MB|MIB|G|GB|GIB|T|TB|TIB)?$',
    caseSensitive: false,
  ).firstMatch(raw.trim());
  if (match == null) return null;
  final value = int.tryParse(match.group(1)!);
  if (value == null) return null;
  final multiplier = switch (match.group(2)?.toUpperCase()) {
    null || 'B' => 1,
    'K' || 'KB' || 'KIB' => 1024,
    'M' || 'MB' || 'MIB' => 1024 * 1024,
    'G' || 'GB' || 'GIB' => 1024 * 1024 * 1024,
    'T' || 'TB' || 'TIB' => 1024 * 1024 * 1024 * 1024,
    _ => 0,
  };
  if (multiplier == 0 || value > 0x7fffffffffffffff ~/ multiplier) {
    return null;
  }
  return value * multiplier;
}
