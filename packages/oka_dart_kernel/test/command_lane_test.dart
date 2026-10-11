// FSEvents delivery under load can exceed 30s; the file-level default
// would kill honest waits before the worst case arrives. This machine
// runs several live watchers concurrently — transient timing assertions
// get a bounded retry.
@Timeout(Duration(minutes: 3))
@Retry(3)
library;

import 'dart:async';
import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:test/test.dart';

/// ADR-0038: command lanes turn file-system events under declared roots
/// into serialized, debounced command runs. Receipts are data; the runner
/// never retries and never gates.
void main() {
  late Directory root;
  final receipts = <Map<String, Object?>>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('oka-command-lane-');
    receipts.clear();
  });

  tearDown(() async {
    await root.delete(recursive: true).catchError((_) => root);
  });

  CommandLane lane(
    Map<String, dynamic> json, {
    List<Map<String, Object?>>? into,
  }) {
    final spec = CommandLaneSpec.fromJson(json);
    return CommandLane(
      spec: spec,
      projectRoot: root.path,
      onReceipt: into == null ? (_) {} : into.add,
    );
  }

  Future<void> until(
    bool Function() condition, {
    // FSEvents delivery latency on macOS swings from milliseconds to
    // several seconds under load; waits must budget for the worst case.
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not met within ${timeout.inMilliseconds} ms');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> touch(String path, [String content = 'x']) async {
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(content);
  }

  /// Resolves once the lane is quiescent: every started run has its
  /// receipt and no new receipt arrived for [quiet]. FSEvents can deliver
  /// earlier touches seconds late under load — this window lets stale
  /// events land before the caller counts runs or asserts an absence.
  Future<void> idle({
    Duration quiet = const Duration(seconds: 2),
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var seen = receipts.length;
    var lastChange = DateTime.now();
    while (true) {
      if (receipts.length != seen) {
        seen = receipts.length;
        lastChange = DateTime.now();
      }
      int named(String event) =>
          receipts.where((receipt) => receipt['event'] == event).length;
      final settled = named('command_start') == named('command_receipt');
      if (settled && DateTime.now().difference(lastChange) >= quiet) return;
      if (DateTime.now().isAfter(deadline)) {
        fail('lane never went idle; receipts: $receipts');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Directory.watch subscriptions establish asynchronously on macOS and
  /// may drop events that land during wiring; warm up with retried canary
  /// touches so "the lane is live" is deterministic before assertions.
  /// The lane is handed over only after it has drained (no run in flight,
  /// no fresh receipt), so canary stragglers cannot pollute the caller's
  /// run counts.
  Future<void> warmUp(CommandLane lane$, Directory watched) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    for (var attempt = 0; attempt < 10; attempt++) {
      await touch('${watched.path}/warmup$attempt.dart');
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (DateTime.now().isBefore(deadline)) {
        if (receipts.any((receipt) => receipt['event'] == 'command_receipt')) {
          await idle();
          receipts.clear();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    fail('lane never delivered a receipt for any canary touch');
  }

  test('spec defaults and validation', () {
    final spec = CommandLaneSpec.fromJson({
      'name': 'ota',
      'watch': ['/tmp/a'],
      'run': ['zsh', 'build.sh'],
    });
    expect(spec.debounceMs, 500);
    expect(spec.extensions, isEmpty);
    expect(spec.project, isNull);
    expect(
      () => CommandLaneSpec.fromJson({
        'watch': <String>[],
        'run': ['x'],
      }),
      throwsArgumentError,
    );
    expect(
      () => CommandLaneSpec.fromJson({
        'name': 'x',
        'run': ['x'],
      }),
      throwsArgumentError,
    );
    expect(
      () => CommandLaneSpec.fromJson({
        'name': 'x',
        'watch': ['/tmp'],
      }),
      throwsArgumentError,
    );
  });

  test('a saved file under a watch root triggers exactly one run', () async {
    final log = File('${root.path}/log');
    final watched = Directory('${root.path}/watched')..createSync();
    final lane$ = lane({
      'name': 'marker',
      'watch': [watched.path],
      'run': ['sh', '-c', 'echo run >> ${log.path}'],
      'debounceMs': 50,
    }, into: receipts);
    lane$.start();
    await warmUp(lane$, watched);
    log.deleteSync();
    await touch('${watched.path}/unit.dart');
    await until(() => log.existsSync() && log.readAsStringSync() == 'run\n');
    expect(
      receipts.map((r) => r['event']),
      containsAllInOrder(['command_start', 'command_receipt']),
    );
    final receipt = receipts.last;
    expect(receipt['lane'], 'marker');
    expect(receipt['ok'], isTrue);
    expect(receipt['exitCode'], 0);
    await lane$.stop();
  });

  test('a burst of saves coalesces into one run', () async {
    final log = File('${root.path}/log');
    final watched = Directory('${root.path}/watched')..createSync();
    final lane$ = lane({
      'name': 'burst',
      'watch': [watched.path],
      'run': ['sh', '-c', 'echo run >> ${log.path}'],
      'debounceMs': 120,
    }, into: receipts);
    lane$.start();
    await warmUp(lane$, watched);
    log.deleteSync();
    receipts.clear();
    for (var i = 0; i < 5; i++) {
      await touch('${watched.path}/unit.dart', 'v$i');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await until(log.existsSync);
    // The lane must go quiet with the burst still a single run; a second
    // run (storm or straggler) would extend this wait and then fail the
    // exact counts below — no fixed settle window to race.
    await idle();
    expect(log.readAsStringSync(), 'run\n', reason: 'one run only: $receipts');
    expect(
      receipts.where((r) => r['event'] == 'command_start'),
      hasLength(1),
      reason: 'five coalesced saves are exactly one run: $receipts',
    );
    await lane$.stop();
  });

  test(
    'an event during a run never overlaps and a burst never storms',
    () async {
      final log = File('${root.path}/log');
      final lockDir = '${root.path}/overlap-lock';
      final watched = Directory('${root.path}/watched')..createSync();
      // ~400 ms run: constructed so the second event lands mid-run. A run
      // entering while the lock is held is the overlap witness.
      final serialScript =
          'mkdir $lockDir 2>/dev/null || '
          'echo OVERLAP >> ${log.path}; '
          'echo start >> ${log.path}; sleep 0.4; '
          'echo end >> ${log.path}; rmdir $lockDir 2>/dev/null';
      final lane$ = lane({
        'name': 'serial',
        'watch': [watched.path],
        'run': ['sh', '-c', serialScript],
        'debounceMs': 50,
      }, into: receipts);
      lane$.start();
      await warmUp(lane$, watched);
      // Anchor the run count in the log, not in receipts: the log carries
      // every run the warm-up already performed.
      final runsBefore = log
          .readAsLinesSync()
          .where((line) => line == 'start')
          .length;
      await touch('${watched.path}/a.dart');
      await until(() {
        final lines = log.readAsLinesSync();
        return lines.where((line) => line == 'start').length > runsBefore;
      });
      // Touched only after run 1 visibly started, so this event provably
      // cannot coalesce into run 1's debounce window: it either lands
      // mid-run (the serialized follow-up) or just after it — one extra
      // run either way. FSEvents delivery spacing no longer matters.
      await touch('${watched.path}/b.dart');
      await until(() {
        final lines = log.readAsLinesSync();
        return lines.where((line) => line == 'start').length >=
                runsBefore + 2 &&
            lines.last == 'end';
      });
      final lines = log.readAsLinesSync();
      final starts = <int>[
        for (var i = 0; i < lines.length; i++)
          if (lines[i] == 'start') i,
      ];
      expect(
        lines.where((line) => line == 'OVERLAP'),
        isEmpty,
        reason: 'runs overlapped: $lines',
      );
      final runs = starts.length - runsBefore;
      expect(
        runs,
        lessThanOrEqualTo(2),
        reason: 'a two-event burst must not storm: $lines',
      );
      expect(
        runs,
        greaterThanOrEqualTo(2),
        reason: 'the mid-run event must produce its own run: $lines',
      );
      // Serialization, positively: the follow-up run started only after the
      // first burst run had ended (the lock witness proves exclusivity).
      final secondStart = starts[runsBefore + 1];
      final firstBurstEnd = lines.lastIndexOf('end', secondStart - 1);
      expect(
        firstBurstEnd,
        greaterThan(starts[runsBefore]),
        reason: 'follow-up started before the first burst run ended: $lines',
      );
      await lane$.stop();
    },
  );

  test('the extension filter drops non-matching events', () async {
    final watched = Directory('${root.path}/watched')..createSync();
    final marker = File('${root.path}/ran');
    final lane$ = lane({
      'name': 'filtered',
      'watch': [watched.path],
      'run': ['sh', '-c', 'touch ${root.path}/ran'],
      'extensions': ['.dart'],
      'debounceMs': 50,
    }, into: receipts);
    lane$.start();
    await warmUp(lane$, watched);
    // The warm-up run legitimately created the marker and warm-up canary
    // events are fully drained; only an event AFTER this point may
    // recreate the marker or produce a receipt.
    marker.deleteSync();
    receipts.clear();
    await touch('${watched.path}/notes.txt');
    // A .txt run would land within this delivered-quiet window (>= 2 s of
    // receipt silence) — far past the 50 ms debounce. No fixed window to
    // undershoot.
    await idle();
    expect(
      marker.existsSync(),
      isFalse,
      reason: 'a .txt event must not trigger a run',
    );
    expect(receipts, isEmpty, reason: 'a .txt event must not trigger a run');
    // Positive control: a matching event right after still runs — the
    // lane stayed live through the quiet window above, so the absence is
    // the filter's doing, not a dead subscription.
    await touch('${watched.path}/kept.dart');
    await until(marker.existsSync);
    await lane$.stop();
  });

  test('runCommandLanes composes typed lanes and emits ready', () async {
    final watched = Directory('${root.path}/watched')..createSync();
    final ready = Completer<void>();
    unawaited(
      runCommandLanes(
        projectRoot: root.path,
        lanes: [
          CommandLaneSpec(
            name: 'typed',
            watch: [watched.path],
            run: ['sh', '-c', 'echo run >> ${root.path}/log'],
            debounceMs: 50,
          ),
        ],
        onReceipt: (receipt) {
          receipts.add(receipt);
          if (receipt['event'] == 'ready') ready.complete();
        },
      ),
    );
    await ready.future.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await touch('${watched.path}/unit.dart');
    await until(() => File('${root.path}/log').existsSync());
    expect(
      receipts.map((receipt) => receipt['event']),
      containsAllInOrder(['ready', 'command_start', 'command_receipt']),
    );
  });

  test('a failing command surfaces as ok:false with its exit code', () async {
    final watched = Directory('${root.path}/watched')..createSync();
    final lane$ = lane({
      'name': 'failing',
      'watch': [watched.path],
      'run': ['sh', '-c', 'exit 3'],
      'debounceMs': 50,
    }, into: receipts);
    lane$.start();
    await warmUp(lane$, watched);
    receipts.clear();
    await touch('${watched.path}/unit.dart');
    await until(
      () => receipts.any(
        (r) => r['event'] == 'command_receipt' && r['ok'] == false,
      ),
    );
    final receipt = receipts.last;
    expect(receipt['exitCode'], 3);
    expect(receipt['lane'], 'failing');
    await lane$.stop();
  });
}
