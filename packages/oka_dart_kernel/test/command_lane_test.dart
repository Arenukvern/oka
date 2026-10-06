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

  /// Directory.watch subscriptions establish asynchronously on macOS and
  /// may drop events that land during wiring; warm up with retried canary
  /// touches so "the lane is live" is deterministic before assertions.
  Future<void> warmUp(CommandLane lane$, Directory watched) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    for (var attempt = 0; attempt < 25; attempt++) {
      await touch('${watched.path}/warmup$attempt.dart');
      final deadline = DateTime.now().add(const Duration(milliseconds: 400));
      while (DateTime.now().isBefore(deadline)) {
        if (receipts.any((receipt) => receipt['event'] == 'command_receipt')) {
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
      () => CommandLaneSpec.fromJson({'name': 'x', 'run': ['x']}),
      throwsArgumentError,
    );
    expect(
      () => CommandLaneSpec.fromJson({'name': 'x', 'watch': ['/tmp']}),
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
    for (var i = 0; i < 5; i++) {
      await touch('${watched.path}/unit.dart', 'v$i');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await until(log.existsSync);
    // One quiet period passes; the burst must stay a single run.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(log.readAsStringSync(), 'run\n');
    await lane$.stop();
  });

  test('an event during a run never overlaps and a burst never storms',
      () async {
    final log = File('${root.path}/log');
    final lockDir = '${root.path}/overlap-lock';
    final watched = Directory('${root.path}/watched')..createSync();
    // ~400 ms run: the follow-up event lands mid-run. A second run
    // entering while the lock is held is the overlap witness.
    final serialScript = 'mkdir $lockDir 2>/dev/null || '
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
    final startsBefore = receipts
        .where((receipt) => receipt['event'] == 'command_start')
        .length;
    await touch('${watched.path}/a.dart');
    await touch('${watched.path}/b.dart');
    await until(() {
      final lines = log.readAsLinesSync();
      return lines.where((line) => line == 'start').length >= 3 &&
          lines.last == 'end';
    });
    // The b.dart event may deliver inside or outside the debounce window
    // depending on FSEvents batching; either way it is ONE extra run, and
    // overlapping runs are forbidden outright.
    final lines = log.readAsLinesSync();
    expect(lines.where((line) => line == 'OVERLAP'), isEmpty, reason:
        'runs overlapped: $lines');
    final startsAfter = receipts
        .where((receipt) => receipt['event'] == 'command_start')
        .length;
    expect(startsAfter - startsBefore, lessThanOrEqualTo(2), reason:
        'a two-event burst must not storm: $lines');
    await lane$.stop();
  });

  test('the extension filter drops non-matching events', () async {
    final watched = Directory('${root.path}/watched')..createSync();
    final lane$ = lane({
      'name': 'filtered',
      'watch': [watched.path],
      'run': ['sh', '-c', 'touch ${root.path}/ran'],
      'extensions': ['.dart'],
      'debounceMs': 50,
    }, into: receipts);
    lane$.start();
    await warmUp(lane$, watched);
    // The warm-up run legitimately created the marker; only an event
    // AFTER this point may recreate it.
    File('${root.path}/ran').deleteSync();
    await touch('${watched.path}/notes.txt');
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(File('${root.path}/ran').existsSync(), isFalse);
    expect(receipts, isEmpty, reason: 'a .txt event must not trigger a run');
    await lane$.stop();
  });

  test('a failing command surfaces as ok:false with its exit code',
      () async {
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
