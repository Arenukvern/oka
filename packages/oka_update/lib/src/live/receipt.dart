/// Receipts: the machine-checkable result of a live patch run. A receipt is
/// the artifact a gate asserts on and an operator reads — `describe()`
/// renders the same facts the event ladder streamed.
library;

/// One probe evaluation: the pair of values observed before/after, plus
/// whether it satisfied its expectation.
class ProbeResult {
  ProbeResult({
    required this.probe,
    required this.before,
    required this.after,
    required this.ok,
    this.held = false,
    this.error,
  });

  final String probe;
  final String before;
  final String after;
  final bool ok;

  /// True when the probe declared `mustHold` and the value survived the
  /// apply unchanged — the no-restart evidence.
  final bool held;
  final String? error;

  Map<String, Object?> toJson() => {
        'probe': probe,
        'before': before,
        'after': after,
        'ok': ok,
        'held': held,
        if (error != null) 'error': error,
      };
}

/// Per-target outcome.
class TargetReceipt {
  TargetReceipt({
    required this.targetId,
    required this.kind,
    required this.ok,
    required this.mode,
    this.deltaBytes,
    this.durationMs,
    this.probes = const [],
    this.refusal,
  });

  final String targetId;
  final String kind;

  /// How the delta reached the running program, e.g. `reloadKernel`,
  /// `reloadSources(rootLibUri)`, `dwds reloadSources`, `staged-next-launch`.
  final String mode;
  final bool ok;
  final int? deltaBytes;
  final int? durationMs;
  final List<ProbeResult> probes;

  /// Set when the target never applied (eligibility, connect failure).
  final String? refusal;

  Map<String, Object?> toJson() => {
        'target': targetId,
        'kind': kind,
        'ok': ok,
        'mode': mode,
        if (deltaBytes != null) 'deltaBytes': deltaBytes,
        if (durationMs != null) 'durationMs': durationMs,
        'probes': [for (final p in probes) p.toJson()],
        if (refusal != null) 'refusal': refusal,
      };
}

/// Whole-run outcome; `ok` is true only when every target applied and every
/// probe held or flipped as declared.
class LivePatchReceipt {
  LivePatchReceipt({
    required this.revision,
    required this.unit,
    required this.ok,
    required this.targets,
    this.refusal,
    DateTime? startedAt,
    DateTime? finishedAt,
  })  : startedAt = startedAt ?? DateTime.now(),
        finishedAt = finishedAt ?? DateTime.now();

  final String revision;
  final String unit;
  final bool ok;
  final List<TargetReceipt> targets;

  /// Session-level refusal (before any target was touched).
  final String? refusal;
  final DateTime startedAt;
  final DateTime finishedAt;

  Map<String, Object?> toJson() => {
        'revision': revision,
        'unit': unit,
        'ok': ok,
        if (refusal != null) 'refusal': refusal,
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt.toIso8601String(),
        'targets': [for (final t in targets) t.toJson()],
      };

  /// Human-readable run report (the debug view).
  String describe() {
    final b = StringBuffer()
      ..writeln('live patch ${ok ? 'OK' : 'FAILED'} — unit `$unit` rev $revision');
    if (refusal != null) b.writeln('  refused: $refusal');
    for (final t in targets) {
      b.writeln('  ${t.ok ? '✓' : '✗'} ${t.targetId} (${
          t.kind}) via ${t.mode}'
          '${t.deltaBytes != null ? ', delta ${t.deltaBytes}B' : ''}'
          '${t.durationMs != null ? ', ${t.durationMs}ms' : ''}');
      if (t.refusal != null) b.writeln('      refused: ${t.refusal}');
      for (final p in t.probes) {
        b.writeln('      probe `${p.probe}`: ${p.before} -> ${p.after}'
            '${p.held ? ' (held)' : ''}${p.error != null ? ' — ${p.error}' : ''}');
      }
    }
    return b.toString().trimRight();
  }
}
