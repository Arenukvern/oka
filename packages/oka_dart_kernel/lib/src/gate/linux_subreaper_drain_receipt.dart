/// Bounded structured receipt for subreaper drain (supervisor control log).
final class SubreaperDrainReceipt {
  SubreaperDrainReceipt({
    required this.phase,
    required this.remainingMs,
    this.observations = const [],
    this.errors = const [],
    this.reapedZombies = 0,
    this.enumerateSource = 'ps',
  });

  final String phase;
  final int remainingMs;
  final List<String> observations;
  final List<String> errors;
  final int reapedZombies;
  final String enumerateSource;

  static const _fieldOrder = [
    'phase',
    'remaining_ms',
    'enumerate',
    'reaped_zombies',
    'obs',
    'errors',
  ];

  String toControlLine() {
    final obs = observations.take(8).join(',');
    final err = errors.take(4).map((e) => e.replaceAll('|', '_')).join('|');
    return 'oka_dev_supervisor_drain_diag '
        'phase=$phase remaining_ms=$remainingMs '
        'enumerate=$enumerateSource reaped_zombies=$reapedZombies '
        'obs=$obs errors=$err';
  }
}

String _extractDiagField(String body, String key) {
  final needle = '$key=';
  final start = body.indexOf(needle);
  if (start < 0) return '';
  final from = start + needle.length;
  var end = body.length;
  for (final k in SubreaperDrainReceipt._fieldOrder) {
    if (k == key) continue;
    final at = body.indexOf(' $k=', from);
    if (at >= 0 && at < end) end = at;
  }
  return body.substring(from, end);
}

SubreaperDrainReceipt? parseSubreaperDrainDiag(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith('oka_dev_supervisor_drain_diag ')) return null;
  final body = trimmed.substring('oka_dev_supervisor_drain_diag '.length);
  final phase = _extractDiagField(body, 'phase').trim();
  if (phase.isEmpty) return null;
  final remainingMs = int.tryParse(_extractDiagField(body, 'remaining_ms')) ?? 0;
  final enumerate = _extractDiagField(body, 'enumerate').trim();
  final reaped = int.tryParse(_extractDiagField(body, 'reaped_zombies')) ?? 0;
  final obsRaw = _extractDiagField(body, 'obs').trim();
  final errRaw = _extractDiagField(body, 'errors').trim();
  return SubreaperDrainReceipt(
    phase: phase,
    remainingMs: remainingMs,
    reapedZombies: reaped,
    enumerateSource: enumerate.isEmpty ? 'ps' : enumerate,
    observations: obsRaw.isEmpty ? const [] : obsRaw.split(','),
    errors: errRaw.isEmpty ? const [] : errRaw.split('|'),
  );
}
