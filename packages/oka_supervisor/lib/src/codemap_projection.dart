/// Read-only projection of codemap's declared command lanes (codemap
/// ADR-0034) into supervisor-style findings.
///
/// ADR-0041 law 7: the supervisor owns the schema, not the
/// implementation language — a foreign runner's declarations are read,
/// never executed. Everything here parses JSON and stats files; nothing
/// spawns, imports, or writes.
///
/// Schema found in the codemap repo (read, not assumed):
///
/// - Declarations live in `tools/ops/project_lanes.py` (typed Python:
///   a `LANES` list of `CommandLaneSpec`) or the equivalent data form
///   `<root>/scripts/lanes.json` — `{"lanes": [spec, ...]}` where a
///   spec carries `name`, `run` (argv), exactly one trigger (`watch`
///   roots or `interval_s` seconds), plus `extensions`, `exclude_dirs`,
///   `project`, `promise`, `timeout_s`, `run_on_start`. The runner's
///   `--list` audit surface prints the same specs as
///   `{"declaration": <path>, "lanes": [...]}`; both documents are
///   accepted here, and unknown spec keys are refused loudly exactly as
///   codemap refuses them at load time.
/// - Receipts are the runner's stdout JSON lines (`ready`, `run_start`,
///   `run_receipt`, `exit` — sequence numbers and durations, never
///   wall-clock timestamps, per codemap's ADR-0033 journal
///   convention). Codemap persists no receipt files, so receipt
///   evidence is read from wherever a capture landed: a redirected
///   daemon log (JSONL), a saved `--once` output (one JSON document),
///   or a directory of such captures. A receipt's observed time is the
///   carrying file's mtime; the comparison clock is injected.
///
/// Finding semantics (deterministic, no hidden defaults):
///
/// - `ready` — interval lane whose newest receipt is younger than its
///   declared cadence; a future-mtime receipt clamps to age zero.
/// - `overdue` — interval lane whose newest receipt age is >= cadence.
/// - `unrun` — declared lane with no valid receipt observed.
/// - `unknown` — report-never-guess: a watch or triggerless lane has
///   no cadence to judge, and a never-run triggerless lane is expected
///   (forced one-shot specs), so neither is ever a failure.
/// - `corruptReceipt` — unparseable receipt evidence naming this lane
///   with no valid receipt to supersede it; unattributable corrupt
///   input counts only in the `receipts.corrupt` summary.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Codes that make `--check` (the future CI hook, ADR-0041 rung 2)
/// fail: an interval missed, a declared lane never observed, or
/// unreadable evidence.
const _attentionCodes = <String>{'overdue', 'unrun', 'corruptReceipt'};

/// The spec keys codemap's data form accepts (its runner refuses
/// unknown keys; so does this parser).
const _laneKeys = <String>{
  'name',
  'run',
  'watch',
  'extensions',
  'interval_s',
  'exclude_dirs',
  'project',
  'promise',
  'timeout_s',
  'run_on_start',
  'trigger',
};

/// One declared lane, read (never executed) from a codemap snapshot.
final class CodemapLane {
  const CodemapLane({
    required this.name,
    required this.run,
    this.watch = const <String>[],
    this.extensions = const <String>[],
    this.intervalS,
    this.excludeDirs = const <String>[],
    this.project,
    this.promise = '',
    this.timeoutS,
    this.runOnStart = false,
  });

  /// Strict parse of one data-form spec: unknown keys and a malformed
  /// trigger fail with [FormatException], lane-named like codemap's
  /// own load-time validation.
  factory CodemapLane.fromJson(final Map<String, Object?> json) {
    final name = json['name'];
    final label = 'command lane ${name is String ? _quote(name) : '<unnamed>'}';
    final unknown = json.keys.toSet().difference(_laneKeys);
    if (unknown.isNotEmpty) {
      throw FormatException('$label: unknown spec keys ${_sorted(unknown)}');
    }
    return CodemapLane(
      name: _string(name, '$label "name"'),
      run: _strings(json['run'], '$label "run"'),
      watch: _strings(json['watch'], '$label "watch"'),
      extensions: _dotSuffixes(json['extensions'], label),
      intervalS: _positiveInt(json['interval_s'], '$label "interval_s"'),
      excludeDirs: _strings(json['exclude_dirs'], '$label "exclude_dirs"'),
      project: _optionalString(json['project'], '$label "project"'),
      promise: _optionalString(json['promise'], '$label "promise"') ?? '',
      timeoutS: _positiveInt(json['timeout_s'], '$label "timeout_s"'),
      runOnStart: _optionalBool(json['run_on_start'], label),
    ).._checkTrigger(json['trigger']);
  }

  final String name;

  /// The declared argv (no shell). Read for the audit surface; this
  /// projection never runs it.
  final List<String> run;
  final List<String> watch;
  final List<String> extensions;

  /// Interval cadence in seconds; null on watch and triggerless lanes.
  final int? intervalS;
  final List<String> excludeDirs;
  final String? project;
  final String promise;
  final int? timeoutS;
  final bool runOnStart;

  /// `watch | interval | manual` — codemap's trigger property, with
  /// `manual` for triggerless specs (constructible for forced one-shot
  /// runs; codemap's daemon refuses them).
  String get trigger => watch.isNotEmpty
      ? 'watch'
      : intervalS != null
      ? 'interval'
      : 'manual';

  Map<String, Object?> toJson() => {
    'name': name,
    'run': List<String>.of(run),
    'trigger': trigger,
    if (watch.isNotEmpty) 'watch': List<String>.of(watch),
    if (extensions.isNotEmpty) 'extensions': List<String>.of(extensions),
    if (intervalS != null) 'interval_s': intervalS,
    if (excludeDirs.isNotEmpty) 'exclude_dirs': List<String>.of(excludeDirs),
    if (project != null) 'project': project,
    if (promise.isNotEmpty) 'promise': promise,
    if (timeoutS != null) 'timeout_s': timeoutS,
    if (runOnStart) 'run_on_start': true,
  };

  void _checkTrigger(final Object? declared) {
    if (declared == null) return;
    if (declared is! String || declared != trigger) {
      throw FormatException(
        'command lane ${_quote(name)}: declared trigger '
        '"$declared" contradicts the spec (computed "$trigger")',
      );
    }
  }
}

/// A parsed lanes snapshot: codemap's data form (`{"lanes": [...]}`) or
/// the runner's `--list` audit document (which adds a `declaration`
/// path — tolerated here).
final class CodemapLaneSnapshot {
  const CodemapLaneSnapshot({required this.lanes, this.declarationPath});

  /// Parses snapshot text; refuses an empty lane list and duplicate
  /// lane names (the runner refuses both at load).
  factory CodemapLaneSnapshot.parse(final String text) {
    final document = jsonDecode(text) as Map<String, Object?>;
    final rawLanes = document['lanes'];
    if (rawLanes is! List || rawLanes.isEmpty) {
      throw const FormatException(
        'lane declaration needs a non-empty "lanes" list',
      );
    }
    final lanes = <CodemapLane>[
      for (final entry in rawLanes) CodemapLane.fromJson(_entryMap(entry)),
    ];
    final names = lanes.map((final lane) => lane.name).toSet();
    if (names.length != lanes.length) {
      throw const FormatException('duplicate lane names in snapshot');
    }
    final declaration = document['declaration'];
    return CodemapLaneSnapshot(
      lanes: lanes,
      declarationPath: declaration is String ? declaration : null,
    );
  }

  final List<CodemapLane> lanes;

  /// The `declaration` path from a `--list` capture, when present.
  final String? declarationPath;
}

Map<String, Object?> _entryMap(final Object? entry) {
  if (entry is Map<String, Object?>) return entry;
  throw FormatException(
    'lane entry must be a mapping, got ${entry?.runtimeType ?? 'null'}',
  );
}

/// One observed lane receipt. Codemap emits these as stdout JSON lines
/// carrying no wall clock, so [receivedAt] is when the carrying file
/// was last modified.
final class CodemapReceipt {
  const CodemapReceipt({
    required this.lane,
    required this.receivedAt,
    required this.ok,
    required this.sourcePath,
    this.exitCode,
    this.durationMs,
    this.error,
  });

  final String lane;
  final DateTime receivedAt;
  final bool ok;
  final String sourcePath;
  final int? exitCode;
  final int? durationMs;
  final String? error;
}

/// Receipt evidence that names a lane but fails receipt validation.
final class CodemapCorruptReceipt {
  const CodemapCorruptReceipt({required this.path, this.lane});

  final String path;

  /// The named lane, when the lane field itself was readable.
  final String? lane;
}

/// Everything a receipts scan observed. Pure evidence: [scanned] counts
/// receipt-shaped inputs examined (valid plus corrupt; the runner's
/// `ready` / `run_start` / `exit` control events are neither).
final class CodemapReceiptScan {
  const CodemapReceiptScan({
    this.receipts = const <CodemapReceipt>[],
    this.scanned = 0,
    this.corrupt = const <CodemapCorruptReceipt>[],
  });

  final List<CodemapReceipt> receipts;
  final int scanned;
  final List<CodemapCorruptReceipt> corrupt;
}

class _ScanAccumulator {
  final receipts = <CodemapReceipt>[];
  final corrupt = <CodemapCorruptReceipt>[];
  int scanned = 0;
}

/// Reads receipt evidence from [path]: a directory (each direct child
/// file is one capture; dotfiles are skipped) or a single file. Each
/// capture may be a pretty-printed JSON document (a saved `--once`
/// output) or a JSONL line stream (a redirected daemon log). Read-only.
CodemapReceiptScan scanCodemapReceipts(final String path) {
  final accumulator = _ScanAccumulator();
  final type = FileSystemEntity.typeSync(path);
  if (type == FileSystemEntityType.notFound) {
    return const CodemapReceiptScan();
  }
  final entities = type == FileSystemEntityType.directory
      ? Directory(path).listSync()
      : <FileSystemEntity>[File(path)];
  final files = entities.whereType<File>().toList()
    ..sort((final a, final b) => a.path.compareTo(b.path));
  for (final file in files) {
    if (p.basename(file.path).startsWith('.')) continue;
    _scanReceiptFile(file, accumulator);
  }
  return CodemapReceiptScan(
    receipts: accumulator.receipts,
    scanned: accumulator.scanned,
    corrupt: accumulator.corrupt,
  );
}

void _scanReceiptFile(final File file, final _ScanAccumulator into) {
  final receivedAt = file.statSync().modified;
  final text = file.readAsStringSync();
  try {
    _absorb(jsonDecode(text), file.path, receivedAt, into);
    return;
  } on FormatException {
    // Not one JSON document: fall through to the JSONL form.
  }
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) continue;
    try {
      _absorb(jsonDecode(line), file.path, receivedAt, into);
    } on FormatException {
      into.scanned += 1;
      into.corrupt.add(CodemapCorruptReceipt(path: file.path));
    }
  }
}

void _absorb(
  final Object? decoded,
  final String path,
  final DateTime receivedAt,
  final _ScanAccumulator into,
) {
  final event = decoded is Map<String, Object?> ? decoded['event'] : null;
  if (event is String && event != 'run_receipt') {
    return; // runner control event (ready/run_start/exit): not evidence
  }
  into.scanned += 1;
  if (decoded is! Map<String, Object?>) {
    into.corrupt.add(CodemapCorruptReceipt(path: path));
    return;
  }
  final lane = decoded['lane'];
  final ok = decoded['ok'];
  final exitCode = decoded['exit_code'];
  final durationMs = decoded['duration_ms'];
  final namedLane = lane is String && lane.isNotEmpty ? lane : null;
  if (namedLane == null ||
      ok is! bool ||
      exitCode is! int ||
      durationMs is! int) {
    into.corrupt.add(CodemapCorruptReceipt(path: path, lane: namedLane));
    return;
  }
  final error = decoded['error'];
  into.receipts.add(
    CodemapReceipt(
      lane: namedLane,
      receivedAt: receivedAt,
      ok: ok,
      sourcePath: path,
      exitCode: exitCode,
      durationMs: durationMs,
      error: error is String ? error : null,
    ),
  );
}

/// One lane's projection: the declared shape plus the newest receipt
/// observation, judged against the lane's cadence.
final class CodemapLaneFinding {
  const CodemapLaneFinding({
    required this.code,
    required this.id,
    required this.trigger,
    required this.message,
    this.intervalS,
    this.lastReceiptAt,
    this.ageS,
  });

  /// `ready | overdue | unrun | unknown | corruptReceipt`.
  final String code;
  final String id;
  final String trigger;
  final String message;
  final int? intervalS;
  final DateTime? lastReceiptAt;
  final int? ageS;

  Map<String, Object?> toJson() => {
    'id': id,
    'trigger': trigger,
    if (intervalS != null) 'intervalS': intervalS,
    if (lastReceiptAt != null)
      'lastReceiptAt': lastReceiptAt!.toIso8601String(),
    if (ageS != null) 'ageS': ageS,
    'finding': {'code': code, 'message': message},
  };
}

/// The whole read-only projection: one finding per declared lane plus
/// the receipts summary.
final class CodemapProjection {
  const CodemapProjection({
    required this.findings,
    required this.scanned,
    required this.corruptCount,
    required this.orphanCount,
  });

  /// In snapshot declaration order.
  final List<CodemapLaneFinding> findings;
  final int scanned;
  final int corruptCount;

  /// Valid receipts naming no declared lane (the supervisor's orphan
  /// concept, mirrored as a summary count).
  final int orphanCount;

  /// True when any `overdue` / `unrun` / `corruptReceipt` finding
  /// exists — the `--check` gate.
  bool get needsAttention =>
      findings.any((final finding) => _attentionCodes.contains(finding.code));
}

/// Pure projection: declared lanes + observed receipts → findings.
/// Highest-effort rule: per lane, the newest valid receipt wins; a
/// corrupt receipt only becomes the lane's finding when no valid
/// receipt exists for it.
List<CodemapLaneFinding> projectCodemapLaneFindings({
  required final CodemapLaneSnapshot snapshot,
  required final CodemapReceiptScan scan,
  required final DateTime now,
}) {
  final newest = <String, CodemapReceipt>{};
  for (final receipt in scan.receipts) {
    final current = newest[receipt.lane];
    if (current == null || !receipt.receivedAt.isBefore(current.receivedAt)) {
      newest[receipt.lane] = receipt;
    }
  }
  final findings = <CodemapLaneFinding>[];
  for (final lane in snapshot.lanes) {
    final corrupt = scan.corrupt
        .where((final entry) => entry.lane == lane.name)
        .toList();
    final receipt = newest[lane.name];
    findings.add(_projectOne(lane, receipt, corrupt, now));
  }
  return findings;
}

CodemapLaneFinding _projectOne(
  final CodemapLane lane,
  final CodemapReceipt? receipt,
  final List<CodemapCorruptReceipt> corrupt,
  final DateTime now,
) {
  final cadenceS = lane.intervalS;
  final trigger = lane.trigger;
  if (receipt == null) {
    if (corrupt.isNotEmpty) {
      return CodemapLaneFinding(
        code: 'corruptReceipt',
        id: lane.name,
        trigger: trigger,
        message:
            'receipt evidence unreadable: '
            '${corrupt.map((final c) => c.path).join(', ')}',
      );
    }
    return CodemapLaneFinding(
      code: trigger == 'manual' ? 'unknown' : 'unrun',
      id: lane.name,
      trigger: trigger,
      intervalS: cadenceS,
      message: switch (trigger) {
        'interval' => 'interval ${cadenceS}s declared; no receipt observed',
        'watch' => 'watch lane declared; no receipt observed',
        _ => 'triggerless lane; nothing is due and nothing was run',
      },
    );
  }
  final age = now.difference(receipt.receivedAt);
  final ageS = age.isNegative ? 0 : age.inSeconds;
  final ageText = _humanAge(ageS);
  if (cadenceS != null) {
    final overdue = ageS >= cadenceS;
    return CodemapLaneFinding(
      code: overdue ? 'overdue' : 'ready',
      id: lane.name,
      trigger: trigger,
      intervalS: cadenceS,
      lastReceiptAt: receipt.receivedAt,
      ageS: ageS,
      message: overdue
          ? 'last receipt $ageText ago; cadence ${cadenceS}s exceeded'
          : 'last receipt $ageText ago; within cadence ${cadenceS}s',
    );
  }
  final verdict = receipt.ok ? '' : '; run failed (exit ${receipt.exitCode})';
  return CodemapLaneFinding(
    code: 'unknown',
    id: lane.name,
    trigger: trigger,
    lastReceiptAt: receipt.receivedAt,
    ageS: ageS,
    message:
        'no cadence to judge ($trigger trigger); last receipt '
        '$ageText ago$verdict',
  );
}

/// Scans receipts when [receiptsPath] is given, projects the lanes, and
/// counts orphan receipts. Read-only; [clock] defaults to
/// [DateTime.now] so tests pin time.
CodemapProjection projectCodemapLanes({
  required final CodemapLaneSnapshot snapshot,
  final String? receiptsPath,
  final DateTime Function()? clock,
}) {
  final scan = receiptsPath == null
      ? const CodemapReceiptScan()
      : scanCodemapReceipts(receiptsPath);
  final findings = projectCodemapLaneFindings(
    snapshot: snapshot,
    scan: scan,
    now: (clock ?? DateTime.now)(),
  );
  final declared = snapshot.lanes.map((final lane) => lane.name).toSet();
  final orphans = scan.receipts
      .where((final receipt) => !declared.contains(receipt.lane))
      .length;
  return CodemapProjection(
    findings: findings,
    scanned: scan.scanned,
    corruptCount: scan.corrupt.length,
    orphanCount: orphans,
  );
}

/// One JSON document: `{lanes: [{id, trigger, lastReceiptAt?, ageS?,
/// finding: {code, message}}], receipts: {scanned, corrupt, orphan}}` —
/// the wire shape for CLI `--json` and a future CI gate.
String projectionJson(final CodemapProjection projection) =>
    const JsonEncoder.withIndent('  ').convert({
      'lanes': [for (final finding in projection.findings) finding.toJson()],
      'receipts': {
        'scanned': projection.scanned,
        'corrupt': projection.corruptCount,
        'orphan': projection.orphanCount,
      },
    });

/// Aligned plain-text rendering for terminals.
String renderProjection(final CodemapProjection projection) {
  final header =
      'codemap lanes: ${projection.findings.length} declared; receipts '
      'scanned=${projection.scanned} corrupt=${projection.corruptCount} '
      'orphan=${projection.orphanCount}';
  final rows = <List<String>>[
    <String>['ID', 'TRIGGER', 'FINDING', 'AGE', 'NOTE'],
    for (final finding in projection.findings)
      <String>[
        finding.id,
        finding.trigger,
        finding.code,
        if (finding.ageS == null) '-' else _humanAge(finding.ageS!),
        finding.message,
      ],
  ];
  final widths = <int>[
    for (var column = 0; column < 5; column++)
      rows.fold(
        0,
        (final max, final row) =>
            row[column].length > max ? row[column].length : max,
      ),
  ];
  return [
    header,
    for (final row in rows)
      [
        for (var column = 0; column < row.length; column++)
          row[column].padRight(widths[column]),
      ].join('  ').trimRight(),
  ].join('\n');
}

String _humanAge(final int seconds) {
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m';
  if (seconds < 86400) return '${seconds ~/ 3600}h';
  return '${seconds ~/ 86400}d';
}

List<String> _strings(final Object? value, final String label) {
  if (value == null) return const <String>[];
  if (value is! List) {
    throw FormatException('$label must be a list of strings');
  }
  return [
    for (final item in value)
      if (item is String && item.isNotEmpty)
        item
      else
        throw FormatException('$label entries must be non-empty strings'),
  ];
}

List<String> _dotSuffixes(final Object? value, final String label) {
  final suffixes = _strings(value, '$label "extensions"');
  for (final suffix in suffixes) {
    if (!suffix.startsWith('.')) {
      throw FormatException(
        '$label "extensions" entries are dot-suffixes (".py"), '
        'got ${_quote(suffix)}',
      );
    }
  }
  return suffixes;
}

String _string(final Object? value, final String label) {
  final text = _optionalString(value, label);
  if (text == null || text.isEmpty) {
    throw FormatException('$label must be a non-empty string');
  }
  return text;
}

String? _optionalString(final Object? value, final String label) {
  if (value == null) return null;
  if (value is! String) throw FormatException('$label must be a string');
  return value;
}

int? _positiveInt(final Object? value, final String label) {
  if (value == null) return null;
  if (value is! int || value <= 0) {
    throw FormatException('$label must be a positive integer');
  }
  return value;
}

bool _optionalBool(final Object? value, final String label) {
  if (value == null) return false;
  if (value is! bool) {
    throw FormatException('$label "run_on_start" must be a boolean');
  }
  return value;
}

String _quote(final String text) => "'$text'";

List<String> _sorted(final Set<String> values) => values.toList()..sort();
