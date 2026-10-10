import 'dart:convert';
import 'dart:io';

import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:test/test.dart';

/// Fixtures mirror the REAL codemap schema (its ADR-0034): data-form
/// lane specs (`{"lanes": [...]}`, keys `name`/`run`/`watch`/
/// `interval_s`/`extensions`/`promise`/... ) and the runner's stdout
/// receipt lines (`event`/`seq`/`lane`/`ok`/`exit_code`/`duration_ms`).
/// Receipts carry no wall clock, so a fixture capture's mtime IS its
/// observed time.
void main() {
  late Directory temp;
  late Directory snapshots;
  late Directory receipts;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('oka-supervisor-codemap-test');
    snapshots = Directory('${temp.path}/snapshots')..createSync();
    receipts = Directory('${temp.path}/receipts')..createSync();
  });
  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  // The fixed clock every test projects against.
  final now = DateTime(2026, 10, 10, 12);

  Map<String, Object?> intervalLane({
    final String name = 'store-refresh',
    final int intervalS = 21600,
  }) => {
    'name': name,
    'run': ['python3', 'tools/ops/refresh_global_store.py', '--families'],
    'trigger': 'interval',
    'interval_s': intervalS,
    'exclude_dirs': <String>[],
    'promise': 'global fact store stays fresh across the portfolio',
  };

  Map<String, Object?> watchLane({final String name = 'aot'}) => {
    'name': name,
    'run': ['/bin/bash', 'tools/ops/build_aot.sh'],
    'trigger': 'watch',
    'watch': <String>['engines/versions/py_engine/kernel'],
    'extensions': <String>['.py', '.rs'],
    'exclude_dirs': <String>['dist', 'build'],
    'run_on_start': true,
    'promise': 'rebuild dist/codemap-mcp and swap atomically',
  };

  Map<String, Object?> receipt(
    final String lane, {
    final bool ok = true,
    final int seq = 3,
  }) => {
    'event': 'run_receipt',
    'seq': seq,
    'lane': lane,
    'ok': ok,
    'exit_code': ok ? 0 : 1,
    'duration_ms': 1234,
  };

  File writeSnapshot(final List<Map<String, Object?>> lanes) =>
      File('${snapshots.path}/lanes.json')..writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({'lanes': lanes}),
      );

  File writeCapture(
    final String name, {
    required final List<Map<String, Object?>> lines,
    required final DateTime at,
    final bool prettyDocument = false,
  }) => File('${receipts.path}/$name')
    ..writeAsStringSync(
      prettyDocument
          ? const JsonEncoder.withIndent('  ').convert(lines.single)
          : [for (final line in lines) jsonEncode(line)].join('\n'),
    )
    ..setLastModifiedSync(at);

  CodemapLaneSnapshot parse(final File file) =>
      CodemapLaneSnapshot.parse(file.readAsStringSync());

  group('snapshot parse', () {
    test('accepts the data form and the --list audit document', () {
      final dataForm = parse(writeSnapshot([watchLane(), intervalLane()]));
      expect(dataForm.declarationPath, isNull);
      expect(dataForm.lanes.map((final lane) => lane.name), [
        'aot',
        'store-refresh',
      ]);
      final listDocument = File('${snapshots.path}/list.json')
        ..writeAsStringSync(
          jsonEncode({
            'declaration': '/repo/tools/ops/project_lanes.py',
            'lanes': [intervalLane()],
          }),
        );
      final fromList = parse(listDocument);
      expect(fromList.declarationPath, '/repo/tools/ops/project_lanes.py');
    });

    test("refuses unknown spec keys, lane-named (codemap's own rule)", () {
      final bad = {...intervalLane(), 'cadence': 60};
      expect(
        () => CodemapLaneSnapshot.parse(
          jsonEncode({
            'lanes': [bad],
          }),
        ),
        throwsA(
          isA<FormatException>().having(
            (final error) => error.message,
            'message',
            allOf(
              contains("command lane 'store-refresh'"),
              contains('unknown spec keys [cadence]'),
            ),
          ),
        ),
      );
    });

    test('refuses two triggers, bad trigger, duplicates, empty lanes', () {
      final both = intervalLane()..['watch'] = <String>['src'];
      expect(
        () => CodemapLaneSnapshot.parse(
          jsonEncode({
            'lanes': [both],
          }),
        ),
        throwsFormatException,
      );
      final mismatch = intervalLane()..['trigger'] = 'watch';
      expect(
        () => CodemapLaneSnapshot.parse(
          jsonEncode({
            'lanes': [mismatch],
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => CodemapLaneSnapshot.parse(
          jsonEncode({
            'lanes': [intervalLane(), intervalLane()],
          }),
        ),
        throwsA(
          isA<FormatException>().having(
            (final error) => error.message,
            'message',
            contains('duplicate lane names'),
          ),
        ),
      );
      expect(
        () => CodemapLaneSnapshot.parse(jsonEncode({'lanes': <Object?>[]})),
        throwsA(
          isA<FormatException>().having(
            (final error) => error.message,
            'message',
            contains('non-empty "lanes" list'),
          ),
        ),
      );
    });

    test('parses trigger and cadence off the real spec fields', () {
      final lanes = parse(writeSnapshot([watchLane(), intervalLane()])).lanes;
      expect(lanes[0].trigger, 'watch');
      expect(lanes[0].intervalS, isNull);
      expect(lanes[0].runOnStart, isTrue);
      expect(lanes[0].run, ['/bin/bash', 'tools/ops/build_aot.sh']);
      expect(lanes[1].trigger, 'interval');
      expect(lanes[1].intervalS, 21600);
    });
  });

  group('interval findings', () {
    test('fresh receipt within cadence is ready', () {
      writeCapture(
        'store-refresh.log',
        lines: [receipt('store-refresh')],
        at: now.subtract(const Duration(hours: 2)),
      );
      final findings = projectCodemapLaneFindings(
        snapshot: parse(writeSnapshot([intervalLane()])),
        scan: scanCodemapReceipts(receipts.path),
        now: now,
      );
      expect(findings.single.code, 'ready');
      expect(findings.single.ageS, 7200);
      expect(
        findings.single.lastReceiptAt,
        now.subtract(const Duration(hours: 2)),
      );
    });

    test('receipt older than cadence is overdue (30h vs 6h)', () {
      writeCapture(
        'store-refresh.log',
        lines: [receipt('store-refresh')],
        at: now.subtract(const Duration(hours: 30)),
      );
      final findings = projectCodemapLaneFindings(
        snapshot: parse(writeSnapshot([intervalLane()])),
        scan: scanCodemapReceipts(receipts.path),
        now: now,
      );
      expect(findings.single.code, 'overdue');
      expect(findings.single.ageS, 30 * 3600);
      expect(findings.single.message, contains('cadence 21600s exceeded'));
    });

    test('age exactly at cadence is overdue', () {
      writeCapture(
        'store-refresh.log',
        lines: [receipt('store-refresh')],
        at: now.subtract(const Duration(seconds: 21600)),
      );
      final findings = projectCodemapLaneFindings(
        snapshot: parse(writeSnapshot([intervalLane()])),
        scan: scanCodemapReceipts(receipts.path),
        now: now,
      );
      expect(findings.single.code, 'overdue');
    });

    test('future-mtime receipt clamps to age zero and is ready', () {
      writeCapture(
        'store-refresh.log',
        lines: [receipt('store-refresh')],
        at: now.add(const Duration(hours: 1)),
      );
      final findings = projectCodemapLaneFindings(
        snapshot: parse(writeSnapshot([intervalLane()])),
        scan: scanCodemapReceipts(receipts.path),
        now: now,
      );
      expect(findings.single.code, 'ready');
      expect(findings.single.ageS, 0);
    });

    test('interval lane without receipts is unrun', () {
      final findings = projectCodemapLaneFindings(
        snapshot: parse(writeSnapshot([intervalLane()])),
        scan: const CodemapReceiptScan(),
        now: now,
      );
      expect(findings.single.code, 'unrun');
      expect(findings.single.message, contains('interval 21600s declared'));
    });
  });

  group('watch and triggerless findings', () {
    test('watch lane with a receipt is unknown (no cadence to judge)', () {
      writeCapture(
        'aot.log',
        lines: [receipt('aot')],
        at: now.subtract(const Duration(hours: 9)),
      );
      final findings = projectCodemapLaneFindings(
        snapshot: parse(writeSnapshot([watchLane()])),
        scan: scanCodemapReceipts(receipts.path),
        now: now,
      );
      expect(findings.single.code, 'unknown');
      expect(findings.single.ageS, 9 * 3600);
    });

    test('watch lane never observed is unrun', () {
      final findings = projectCodemapLaneFindings(
        snapshot: parse(writeSnapshot([watchLane()])),
        scan: const CodemapReceiptScan(),
        now: now,
      );
      expect(findings.single.code, 'unrun');
      expect(findings.single.message, contains('no receipt observed'));
    });

    test('triggerless lane is unknown with or without a receipt', () {
      final manual = {
        'name': 'forced-one-shot',
        'run': <String>['/bin/true'],
        'promise': 'constructed for forced runs',
      };
      final snapshot = parse(writeSnapshot([manual]));
      var findings = projectCodemapLaneFindings(
        snapshot: snapshot,
        scan: const CodemapReceiptScan(),
        now: now,
      );
      expect(findings.single.code, 'unknown');
      writeCapture(
        'manual.log',
        lines: [receipt('forced-one-shot')],
        at: now.subtract(const Duration(minutes: 5)),
      );
      findings = projectCodemapLaneFindings(
        snapshot: snapshot,
        scan: scanCodemapReceipts(receipts.path),
        now: now,
      );
      expect(findings.single.code, 'unknown');
      expect(findings.single.trigger, 'manual');
    });
  });

  group('receipt scanning', () {
    test('reads a pretty-printed --once output as one receipt', () {
      writeCapture(
        'once.json',
        lines: [receipt('store-refresh', seq: 1)],
        at: now.subtract(const Duration(hours: 1)),
        prettyDocument: true,
      );
      final scan = scanCodemapReceipts(receipts.path);
      expect(scan.scanned, 1);
      expect(scan.corrupt, isEmpty);
      expect(scan.receipts.single.lane, 'store-refresh');
      expect(scan.receipts.single.ok, isTrue);
      expect(scan.receipts.single.exitCode, 0);
      expect(scan.receipts.single.durationMs, 1234);
    });

    test('control events are neither scanned nor corrupt', () {
      writeCapture(
        'daemon.log',
        lines: [
          {
            'event': 'ready',
            'seq': 1,
            'lanes': ['aot'],
            'poll_interval_s': 2.0,
            'max_runs': null,
          },
          {'event': 'run_start', 'seq': 2, 'lane': 'aot'},
          receipt('aot'),
          {'event': 'exit', 'seq': 4, 'reason': 'max_runs', 'runs': 1},
        ],
        at: now.subtract(const Duration(minutes: 3)),
      );
      final scan = scanCodemapReceipts(receipts.path);
      expect(scan.scanned, 1);
      expect(scan.receipts.single.lane, 'aot');
      expect(scan.corrupt, isEmpty);
    });

    test('unparseable evidence counts corrupt, attributable or not', () {
      File(
        '${receipts.path}/broken.log',
      ).writeAsStringSync('{"event": "run_receipt", "lane": "aot"\n');
      File('${receipts.path}/named.json').writeAsStringSync(
        jsonEncode({'event': 'run_receipt', 'lane': 'quick-check'}),
      );
      final scan = scanCodemapReceipts(receipts.path);
      expect(scan.scanned, 2);
      expect(scan.corrupt.length, 2);
      expect(
        scan.corrupt.map((final entry) => entry.lane),
        containsAll([null, 'quick-check']),
      );
      final findings = projectCodemapLaneFindings(
        snapshot: parse(
          writeSnapshot([watchLane(), intervalLane(name: 'quick-check')]),
        ),
        scan: scan,
        now: now,
      );
      // quick-check: corrupt attributed, no valid receipt ->
      // corruptReceipt. aot: unattributable corrupt is summary-only.
      expect(findings[0].code, 'unrun');
      expect(findings[1].code, 'corruptReceipt');
      expect(findings[1].message, contains('named.json'));
    });

    test('a valid receipt supersedes attributed corrupt evidence', () {
      File('${receipts.path}/bad.log').writeAsStringSync(
        jsonEncode({'event': 'run_receipt', 'lane': 'aot', 'ok': 'yes'}),
      );
      writeCapture(
        'good.log',
        lines: [receipt('aot', seq: 9)],
        at: now.subtract(const Duration(minutes: 1)),
      );
      final findings = projectCodemapLaneFindings(
        snapshot: parse(writeSnapshot([watchLane()])),
        scan: scanCodemapReceipts(receipts.path),
        now: now,
      );
      expect(findings.single.code, 'unknown');
    });

    test('receipts naming no declared lane count as orphans', () {
      writeCapture(
        'ghost.log',
        lines: [receipt('ghost-lane')],
        at: now.subtract(const Duration(minutes: 1)),
      );
      final projection = projectCodemapLanes(
        snapshot: parse(writeSnapshot([watchLane()])),
        receiptsPath: receipts.path,
        clock: () => now,
      );
      expect(projection.orphanCount, 1);
      expect(projection.findings.single.code, 'unrun');
    });

    test('missing receipts path projects declarations only', () {
      final projection = projectCodemapLanes(
        snapshot: parse(writeSnapshot([watchLane(), intervalLane()])),
        receiptsPath: '${temp.path}/does-not-exist',
        clock: () => now,
      );
      expect(projection.scanned, 0);
      expect(
        projection.findings.map((final finding) => finding.code),
        everyElement('unrun'),
      );
    });
  });

  group('documents and gate', () {
    test('projectionJson carries the documented wire shape', () {
      writeCapture(
        'store-refresh.log',
        lines: [receipt('store-refresh')],
        at: now.subtract(const Duration(hours: 30)),
      );
      final projection = projectCodemapLanes(
        snapshot: parse(writeSnapshot([intervalLane()])),
        receiptsPath: receipts.path,
        clock: () => now,
      );
      final document =
          jsonDecode(projectionJson(projection)) as Map<String, Object?>;
      final lanes = document['lanes']! as List<Object?>;
      final lane = lanes.single! as Map<String, Object?>;
      expect(lane['id'], 'store-refresh');
      expect(lane['trigger'], 'interval');
      expect(lane['intervalS'], 21600);
      expect(lane['ageS'], 30 * 3600);
      expect(lane['lastReceiptAt'], isA<String>());
      expect((lane['finding']! as Map<String, Object?>)['code'], 'overdue');
      final receiptsSummary = document['receipts']! as Map<String, Object?>;
      expect(receiptsSummary, {'scanned': 1, 'corrupt': 0, 'orphan': 0});
    });

    test('renderProjection aligns one line per lane', () {
      final projection = projectCodemapLanes(
        snapshot: parse(writeSnapshot([watchLane(), intervalLane()])),
        clock: () => now,
      );
      final rendered = renderProjection(projection);
      expect(rendered, contains('codemap lanes: 2 declared'));
      expect(rendered, contains('aot'));
      expect(rendered, contains('unrun'));
    });

    test('--check gate: ready is clean, the rest are not', () {
      CodemapProjection gate(final List<CodemapLaneFinding> findings) =>
          CodemapProjection(
            findings: findings,
            scanned: 0,
            corruptCount: 0,
            orphanCount: 0,
          );
      const clean = CodemapLaneFinding(
        code: 'ready',
        id: 'lane',
        trigger: 'interval',
        message: 'ok',
      );
      expect(gate([clean]).needsAttention, isFalse);
      for (final code in const ['overdue', 'unrun', 'corruptReceipt']) {
        expect(
          gate([
            clean,
            CodemapLaneFinding(
              code: code,
              id: 'lane',
              trigger: 'interval',
              message: 'not ok',
            ),
          ]).needsAttention,
          isTrue,
          reason: code,
        );
      }
    });
  });
}
