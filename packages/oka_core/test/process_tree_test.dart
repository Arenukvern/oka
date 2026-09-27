// Real-subprocess tests for the tree-aware process seam (ADR-0026
// decision 8 / R2 gate): a surviving grandchild fails the gate.
//
// POSIX-only: the fixtures use `sh` process chains. Windows follows the
// repo's standing rule — logic is exercised by fakes and golden parsers
// here; host evidence on a Windows runner remains pending.
import 'dart:async';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

void main() {
  if (Platform.isWindows) {
    // Keep the pure parser coverage; the real-subtree fixtures below need
    // POSIX `sh` chains and `ps`.
    _pureParserTests();
    return;
  }
  _pureParserTests();
  _treeEnumerationTests();
  _treeStopTests();
  _boundedRunTests();
  _runnerDeadlineTests();
}

void _pureParserTests() {
  test('parsePosixProcessParentMap parses ps output and skips junk', () {
    final parentOf = parsePosixProcessParentMap('''
  1     0 /sbin/launchd
 42     1 Terminal
 99    42 sleep 30
  bogus line
 101    99 sh -c 'sleep 30 & wait'
''');
    expect(parentOf[42], 1);
    expect(parentOf[99], 42);
    expect(parentOf[101], 99);
    expect(parentOf.containsKey(0), isFalse);
  });

  test('parsePosixProcessParentMap: subtree BFS is shallowest-first', () {
    const tree = ProcessTree(rootPid: 1, parentOf: {
      1: 0,
      2: 1,
      3: 1,
      4: 2,
      5: 4,
    });
    expect(tree.descendants(), [2, 3, 4, 5]);
  });

  test('parseWindowsProcessParentMap parses pid|ppid rows', () {
    final parentOf = parseWindowsProcessParentMap('''
4|0
9184|3780
9185|9184
garbage
''');
    expect(parentOf[9184], 3780);
    expect(parentOf[9185], 9184);
    expect(parentOf.containsKey(4), isTrue);
  });
}

void _treeEnumerationTests() {
  test('HostProcessTreeProbe enumerates a real sh → sleep subtree', () async {
    final process = await Process.start('sh', ['-c', 'sleep 30 & wait']);
    const probe = HostProcessTreeProbe();
    try {
      final tree = await _eventuallyTree(probe, process.pid);
      expect(tree, isNotNull);
      expect(
        tree!.descendants(),
        isNotEmpty,
        reason: 'the background sleep must be discovered as a child',
      );
    } finally {
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
    }
  });
}

void _treeStopTests() {
  test(
    'stopProcessTree stops a parent → child → grandchild chain with zero '
    'survivors (the R2 gate)',
    () async {
      // Depth-3 chain: outer sh → inner sh → sleep.
      final root = await Process.start(
        'sh',
        ['-c', 'sh -c "sleep 30 & wait" & wait'],
      );
      const probe = HostProcessTreeProbe();
      const liveness = HostProcessLiveness();
      try {
        final before = await _eventuallyTree(
          probe,
          root.pid,
          minDescendants: 2,
        );
        expect(before, isNotNull);
        expect(
          before!.descendants().length,
          greaterThanOrEqualTo(2),
          reason: 'inner sh and sleep must both be discovered',
        );

        final result = await stopProcessTree(
          probe: probe,
          liveness: liveness,
          rootPid: root.pid,
          rootIdentityToken: await liveness.identityToken(root.pid),
          grace: const Duration(milliseconds: 400),
          settle: const Duration(milliseconds: 100),
        );
        expect(result.stopped, isTrue, reason: 'notes: ${result.notes}');
        expect(result.survivors, isEmpty);
        for (final pid in <int>[root.pid, ...before.descendants()]) {
          expect(
            await liveness.isAlive(pid),
            isFalse,
            reason: 'pid $pid must be verified dead after the ladder',
          );
        }
      } finally {
        root.kill();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('stopProcessTree refuses a recycled root and signals nothing',
      () async {
    final probe = _FakeProbe(const {
      100: 1,
      101: 100,
    });
    final liveness = _FakeLiveness(alivePids: {100, 101}, token: 'other');
    final result = await stopProcessTree(
      probe: probe,
      liveness: liveness,
      rootPid: 100,
      rootIdentityToken: 'mine',
      grace: const Duration(milliseconds: 10),
    );
    expect(result.stopped, isFalse);
    expect(result.survivors, [100, 101]);
    expect(result.notes.join(' '), contains('recycled'));
    expect(liveness.killCalls, isEmpty, reason: 'report-never-guess');
  });

  test('stopProcessTree reports unknown (not empty) when the table '
      'cannot be read', () async {
    final probe = _UnreadableProbe();
    final liveness = _FakeLiveness(alivePids: {7}, token: 't');
    final result = await stopProcessTree(
      probe: probe,
      liveness: liveness,
      rootPid: 7,
      grace: const Duration(milliseconds: 10),
    );
    expect(result.stopped, isFalse);
    expect(result.survivors, isEmpty);
    expect(result.notes.join(' '), contains('unknown'));
  });
}

void _boundedRunTests() {
  test('runBoundedProcess: clean exit captures bounded output', () async {
    final result = await runBoundedProcess('sh', [
      '-c',
      'echo hello; echo oops >&2',
    ], timeout: const Duration(seconds: 10));
    expect(result.cause, BoundedRunCause.exited);
    expect(result.ok, isTrue);
    expect(result.stdout, contains('hello'));
    expect(result.stderr, contains('oops'));
    expect(result.truncatedOutput, isFalse);
    expect(result.rootPid, greaterThan(0));
  });

  test('runBoundedProcess: deadline kills the tree, never abandons it',
      () async {
    const liveness = HostProcessLiveness();
    final result = await runBoundedProcess(
      'sh',
      ['-c', 'sh -c "sleep 30 & wait" & wait'],
      timeout: const Duration(milliseconds: 500),
      grace: const Duration(milliseconds: 300),
      settle: const Duration(milliseconds: 100),
    );
    expect(result.cause, BoundedRunCause.killedOnDeadline);
    expect(result.survivors, isEmpty, reason: 'zero-survivor gate');
    expect(result.duration, lessThan(const Duration(seconds: 10)));
    expect(
      await liveness.isAlive(result.rootPid!),
      isFalse,
      reason: 'the child must be verified dead, not abandoned',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('runBoundedProcess: SIGTERM-ignoring child still dies (force rung)',
      () async {
    const liveness = HostProcessLiveness();
    final result = await runBoundedProcess(
      'sh',
      ['-c', 'trap "" TERM; sleep 30'],
      timeout: const Duration(milliseconds: 400),
      grace: const Duration(milliseconds: 300),
    );
    expect(result.cause, BoundedRunCause.killedOnDeadline);
    expect(result.survivors, isEmpty);
    expect(await liveness.isAlive(result.rootPid!), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('runBoundedProcess: capture bound truncates and flags', () async {
    final result = await runBoundedProcess(
      'sh',
      ['-c', 'seq 1 2000 | tr "\n" "-"'],
      timeout: const Duration(seconds: 10),
      maxCapturedBytes: 64,
    );
    expect(result.truncatedOutput, isTrue);
    expect(result.stdout.length, lessThanOrEqualTo(64));
  });

  test('runBoundedProcess: spawn failure is a named cause', () async {
    final result = await runBoundedProcess('definitely-not-a-binary-oka', const [
      'x',
    ], timeout: const Duration(seconds: 5));
    expect(result.cause, BoundedRunCause.spawnFailed);
    expect(result.errorMessage, isNotNull);
  });
}

void _runnerDeadlineTests() {
  test('SystemProcessRunner keeps the TimeoutException contract — but the '
      'child is dead', () async {
    const runner = SystemProcessRunner();
    await expectLater(
      runner.run('sh', ['-c', 'sleep 30'], timeout: const Duration(milliseconds: 400)),
      throwsA(isA<TimeoutException>()),
    );
  });
}

Future<ProcessTree?> _eventuallyTree(
  ProcessTreeProbe probe,
  int rootPid, {
  int minDescendants = 1,
}) async {
  ProcessTree? tree;
  for (var attempt = 0; attempt < 100; attempt++) {
    tree = await probe.enumerate(rootPid);
    if (tree != null && tree.descendants().length >= minDescendants) {
      return tree;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return tree;
}

class _FakeProbe implements ProcessTreeProbe {
  _FakeProbe(this.parentOf);

  final Map<int, int> parentOf;

  @override
  Future<ProcessTree?> enumerate(int rootPid) async =>
      ProcessTree(rootPid: rootPid, parentOf: parentOf);
}

class _UnreadableProbe implements ProcessTreeProbe {
  @override
  Future<ProcessTree?> enumerate(int rootPid) async => null;
}

class _FakeLiveness implements ProcessLiveness {
  _FakeLiveness({required this.alivePids, required this.token});

  final Set<int> alivePids;
  final String? token;
  final killCalls = <int>[];

  @override
  Future<bool> isAlive(int pid) async => alivePids.contains(pid);

  @override
  Future<String?> identityToken(int pid) async =>
      alivePids.contains(pid) ? token : null;

  @override
  Future<bool> kill(int pid, {Duration grace = const Duration(seconds: 3)}) async {
    killCalls.add(pid);
    alivePids.remove(pid);
    return true;
  }
}
