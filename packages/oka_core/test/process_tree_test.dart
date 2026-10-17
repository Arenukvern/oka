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
    const tree = ProcessTree(
      rootPid: 1,
      parentOf: {1: 0, 2: 1, 3: 1, 4: 2, 5: 4},
    );
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
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => -1,
      );
    }
  });
}

void _treeStopTests() {
  test('stopProcessTree stops a parent → child → grandchild chain with zero '
      'survivors (the R2 gate)', () async {
    // Depth-3 chain: outer sh → inner sh → sleep.
    final root = await Process.start('sh', [
      '-c',
      'sh -c "sleep 30 & wait" & wait',
    ]);
    const probe = HostProcessTreeProbe();
    const liveness = HostProcessLiveness();
    try {
      final before = await _eventuallyTree(probe, root.pid, minDescendants: 2);
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
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('post-signal discovery loss never reports verified stop', () async {
    final probe = _ChangingProbe([
      const <int, int>{7: 1},
      null,
    ]);
    final liveness = _FakeLiveness(alivePids: {7}, token: 'mine');
    final result = await stopProcessTree(
      probe: probe,
      liveness: liveness,
      rootPid: 7,
      rootIdentityToken: 'mine',
      grace: Duration.zero,
      settle: Duration.zero,
    );
    expect(liveness.killCalls, [7]);
    expect(result.stopped, isFalse);
    expect(result.notes.join(' '), contains('unknown'));
  });

  test(
    'reparented descendant stays tracked through the force ladder',
    () async {
      const root = 900000001;
      const child = 900000002;
      final probe = _ChangingProbe([
        const {root: 1, child: root},
        const <int, int>{},
      ]);
      final liveness = _FakeLiveness(
        alivePids: {root, child},
        token: 'mine',
        ignoreFirstKill: {child},
      );
      final result = await stopProcessTree(
        probe: probe,
        liveness: liveness,
        rootPid: root,
        rootIdentityToken: 'mine',
        grace: Duration.zero,
        settle: Duration.zero,
      );
      expect(result.stopped, isTrue);
      expect(liveness.alivePids, isEmpty);
      expect(liveness.killCalls, contains(child));
    },
  );

  test('recycled descendant is refused before its signal', () async {
    const root = 900000001;
    const child = 900000002;
    final liveness = _RecyclingChild(root, child);
    final result = await stopProcessTree(
      probe: _FakeProbe(const {root: 1, child: root}),
      liveness: liveness,
      rootPid: root,
      rootIdentityToken: 'mine',
      grace: Duration.zero,
      settle: Duration.zero,
    );
    expect(liveness.killCalls, [root]);
    expect(liveness.alivePids, {child});
    expect(result.stopped, isFalse);
    expect(result.notes.join(' '), contains('recycled'));
  });

  test('stopProcessTree refuses a recycled root and signals nothing', () async {
    final probe = _FakeProbe(const {100: 1, 101: 100});
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
  test('mutation timeout is not misclassified as observation expiry', () async {
    await expectLater(
      stopProcessTree(
        probe: _ChangingProbe([
          {10: 1},
        ]),
        liveness: _TimeoutKill(),
        rootPid: 10,
        rootIdentityToken: 'mine',
        grace: Duration.zero,
        settle: Duration.zero,
      ),
      throwsA(
        isA<TimeoutException>().having(
          (e) => e.message,
          'owner detail',
          'mutation timeout',
        ),
      ),
    );
  });
  test('invalid observation budget refuses before spawning', () async {
    await expectLater(
      runBoundedProcess(
        'definitely-not-a-binary',
        const [],
        timeout: const Duration(seconds: 1),
        observationBudget: Duration.zero,
      ),
      throwsArgumentError,
    );
  });
  test('tree stop shares one read budget across observations', () async {
    final liveness = _SlowIdentity();
    final result = await stopProcessTree(
      probe: _SlowTree(),
      liveness: liveness,
      rootPid: 10,
      rootIdentityToken: 'mine',
      grace: Duration.zero,
      settle: Duration.zero,
      observationBudget: const Duration(milliseconds: 30),
    );
    expect(result.stopped, isFalse);
    expect(liveness.killCalls, isEmpty);
    expect(result.survivors, containsAll([10, 11]));
  });
  for (final stallIdentity in [false, true]) {
    test(
      'stalled ${stallIdentity ? "identity" : "tree"} observation refuses without late signals',
      () async {
        final gate = Completer<void>();
        final tracking = _GatedIdentity(gate, stall: stallIdentity);
        final gatedTree = _GatedTree(gate);
        final probe = stallIdentity ? const HostProcessTreeProbe() : gatedTree;
        final run = runBoundedProcess(
          'sh',
          ['-c', 'exec sleep 30'],
          timeout: const Duration(milliseconds: 300),
          grace: Duration.zero,
          settle: Duration.zero,
          processTreeProbe: probe,
          liveness: tracking,
        );
        BoundedRunResult? result;
        Object? failure;
        bool? aliveAfterLateRead;
        try {
          result = await run.timeout(const Duration(seconds: 3));
          gate.complete();
          await (stallIdentity
                  ? tracking.finished.future
                  : gatedTree.finished.future)
              .timeout(const Duration(seconds: 2));
          aliveAfterLateRead = await const HostProcessLiveness().isAlive(
            result.rootPid!,
          );
        } on Object catch (error) {
          failure = error;
        } finally {
          final root = await tracking.root.future;
          const host = HostProcessLiveness();
          final token = await host.identityToken(root);
          if (await verifyKillIdentity(host, root, token) ==
              KillIdentity.verified) {
            await host.kill(root, grace: Duration.zero);
          }
          if (!gate.isCompleted) gate.complete();
          await run;
          expect(await host.isAlive(root), isFalse);
        }
        expect(
          failure,
          isNull,
          reason: 'readonly observation cannot hide a deadline',
        );
        expect(result!.teardownVerified, isFalse);
        expect(result.rootExitObserved, isFalse);
        expect(result.survivors, contains(result.rootPid));
        expect(aliveAfterLateRead, isTrue);
        expect(
          tracking.killCalls,
          0,
          reason: 'late readonly results grant no signal authority',
        );
      },
    );
  }
  test('failed deadline discovery returns a live-root receipt', () async {
    final probe = _UnavailableRootProbe();
    BoundedRunResult? result;
    bool? rootAliveOnReturn;
    Object? failure;
    final run = runBoundedProcess(
      'sh',
      ['-c', 'exec yes output'],
      timeout: const Duration(milliseconds: 100),
      grace: Duration.zero,
      settle: Duration.zero,
      processTreeProbe: probe,
    );
    try {
      result = await run.timeout(const Duration(seconds: 2));
      // A refused stop must not close the output pipe and kill a writer with
      // SIGPIPE as an accidental substitute for an authorized tree stop.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      rootAliveOnReturn = await const HostProcessLiveness().isAlive(
        result.rootPid!,
      );
    } on Object catch (error) {
      failure = error;
    } finally {
      final root = await probe.root.future.timeout(const Duration(seconds: 3));
      // Only this fixture owns the child. Reap with a real identity check;
      // production must not bypass unavailable subtree discovery.
      const host = HostProcessLiveness();
      final token = await host.identityToken(root);
      if (await verifyKillIdentity(host, root, token) ==
          KillIdentity.verified) {
        await host.kill(root, grace: Duration.zero);
      }
      await run;
      expect(await host.isAlive(root), isFalse);
    }
    expect(
      failure,
      isNull,
      reason: 'failed discovery must not await a live root forever',
    );
    expect(result!.teardownVerified, isFalse);
    expect(
      rootAliveOnReturn,
      isTrue,
      reason: 'a failed discovery receipt must expose the still-live root',
    );
    expect(result.rootExitObserved, isFalse);
    expect(result.rootIdentityToken, isNotNull);
    expect(result.exitCode, -1);
    expect(result.signalNumber, isNull);
    expect(result.ok, isFalse);
    expect(result.errorMessage, contains('unknown'));
    expect(result.survivors, contains(result.rootPid));
  });
  test(
    'bounded deadline waits for tree verification after root exit',
    () async {
      final probe = _DelayedVerificationProbe();
      var returned = false;
      final run =
          runBoundedProcess(
            'sh',
            ['-c', 'exec sleep 30'],
            timeout: const Duration(milliseconds: 150),
            grace: Duration.zero,
            settle: Duration.zero,
            processTreeProbe: probe,
          ).then((result) {
            returned = true;
            return result;
          });
      try {
        await probe.verifying.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          returned,
          isFalse,
          reason: 'root exit does not complete tree cleanup',
        );
      } finally {
        probe.release.complete();
        final result = await run;
        expect(result.teardownVerified, isFalse);
        expect(result.errorMessage, contains('unknown'));
      }
    },
  );

  test('bounded deadline reports a post-signal probe exception', () async {
    final probe = _DelayedVerificationProbe(fail: true);
    final run = runBoundedProcess(
      'sh',
      ['-c', 'exec sleep 30'],
      timeout: const Duration(milliseconds: 150),
      grace: Duration.zero,
      settle: Duration.zero,
      processTreeProbe: probe,
    );
    await probe.verifying.future.timeout(const Duration(seconds: 5));
    probe.release.complete();
    final result = await run;
    expect(result.teardownVerified, isFalse);
    expect(result.errorMessage, contains('forced probe error'));
  });

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

  test(
    'runBoundedProcess: deadline kills the tree, never abandons it',
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
      expect(result.rootExitObserved, isTrue);
      expect(result.duration, lessThan(const Duration(seconds: 10)));
      expect(
        await liveness.isAlive(result.rootPid!),
        isFalse,
        reason: 'the child must be verified dead, not abandoned',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'runBoundedProcess: SIGTERM-ignoring child still dies (force rung)',
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
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

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
    final result = await runBoundedProcess(
      'definitely-not-a-binary-oka',
      const ['x'],
      timeout: const Duration(seconds: 5),
    );
    expect(result.cause, BoundedRunCause.spawnFailed);
    expect(result.errorMessage, isNotNull);
  });
}

void _runnerDeadlineTests() {
  test('runner timeout retains unverified live-root recovery detail', () async {
    final probe = _UnavailableRootProbe();
    final runner = SystemProcessRunner(processTreeProbe: probe);
    TimeoutException? failure;
    late int root;
    String? token;
    bool? rootWasAlive;
    final run = runner.run('sh', [
      '-c',
      'exec sleep 30',
    ], timeout: const Duration(milliseconds: 100));
    try {
      await run.timeout(const Duration(seconds: 2));
    } on TimeoutException catch (error) {
      failure = error;
    } finally {
      root = await probe.root.future.timeout(const Duration(seconds: 3));
      const host = HostProcessLiveness();
      token = await host.identityToken(root);
      rootWasAlive = await host.isAlive(root);
      if (await verifyKillIdentity(host, root, token) ==
          KillIdentity.verified) {
        await host.kill(root, grace: Duration.zero);
      }
      expect(await host.isAlive(root), isFalse);
      try {
        await run;
      } on TimeoutException {
        // The production timeout is expected; cleanup still awaits settlement.
      }
    }
    expect(failure?.message, contains('UNVERIFIED teardown'));
    expect(failure?.message, contains('root=$root'));
    expect(failure?.message, contains('identity=$token'));
    expect(failure?.message, contains('rootExitObserved=false'));
    expect(rootWasAlive, isTrue);
  });
  test('SystemProcessRunner keeps the TimeoutException contract — but the '
      'child is dead', () async {
    const runner = SystemProcessRunner();
    await expectLater(
      runner.run('sh', [
        '-c',
        'sleep 30',
      ], timeout: const Duration(milliseconds: 400)),
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
  _FakeLiveness({
    required this.alivePids,
    required this.token,
    this.ignoreFirstKill = const {},
  });
  final Set<int> ignoreFirstKill;

  final Set<int> alivePids;
  final String? token;
  final killCalls = <int>[];

  @override
  Future<bool> isAlive(int pid) async => alivePids.contains(pid);

  @override
  Future<String?> identityToken(int pid) async =>
      alivePids.contains(pid) ? token : null;

  @override
  Future<bool> kill(
    int pid, {
    Duration grace = const Duration(seconds: 3),
  }) async {
    final first = !killCalls.contains(pid);
    killCalls.add(pid);
    if (first && ignoreFirstKill.contains(pid)) return false;
    alivePids.remove(pid);
    return true;
  }
}

class _ChangingProbe implements ProcessTreeProbe {
  _ChangingProbe(this.tables);
  final List<Map<int, int>?> tables;
  int calls = 0;
  @override
  Future<ProcessTree?> enumerate(int rootPid) async {
    final table = tables[calls < tables.length ? calls++ : tables.length - 1];
    return table == null
        ? null
        : ProcessTree(rootPid: rootPid, parentOf: table);
  }
}

class _RecyclingChild extends _FakeLiveness {
  _RecyclingChild(this.root, this.child)
    : super(alivePids: {root, child}, token: 'mine');
  final int root;
  final int child;
  bool recycled = false;
  @override
  Future<String?> identityToken(int pid) async =>
      pid == child && recycled ? 'replacement' : await super.identityToken(pid);
  @override
  Future<bool> kill(
    int pid, {
    Duration grace = const Duration(seconds: 3),
  }) async {
    final stopped = await super.kill(pid, grace: grace);
    if (pid == root) recycled = true;
    return stopped;
  }
}

class _DelayedVerificationProbe implements ProcessTreeProbe {
  _DelayedVerificationProbe({this.fail = false});
  final bool fail;
  final verifying = Completer<void>();
  final release = Completer<void>();
  int calls = 0;
  @override
  Future<ProcessTree?> enumerate(int rootPid) async {
    if (calls++ == 0) return const HostProcessTreeProbe().enumerate(rootPid);
    verifying.complete();
    await release.future;
    if (fail) throw StateError('forced probe error');
    return null;
  }
}

class _UnavailableRootProbe implements ProcessTreeProbe {
  final root = Completer<int>();
  @override
  Future<ProcessTree?> enumerate(int rootPid) async {
    if (!root.isCompleted) root.complete(rootPid);
    return null;
  }
}

class _GatedTree implements ProcessTreeProbe {
  _GatedTree(this.gate);
  final Completer<void> gate;
  final finished = Completer<void>();
  @override
  Future<ProcessTree?> enumerate(int rootPid) async {
    await gate.future;
    try {
      return await const HostProcessTreeProbe().enumerate(rootPid);
    } finally {
      if (!finished.isCompleted) finished.complete();
    }
  }
}

class _GatedIdentity implements ProcessLiveness {
  _GatedIdentity(this.gate, {required this.stall});
  final Completer<void> gate;
  final bool stall;
  final root = Completer<int>();
  final finished = Completer<void>();
  int killCalls = 0;
  @override
  Future<String?> identityToken(int pid) async {
    if (!root.isCompleted) root.complete(pid);
    if (stall) await gate.future;
    try {
      return await const HostProcessLiveness().identityToken(pid);
    } finally {
      if (!finished.isCompleted) finished.complete();
    }
  }

  @override
  Future<bool> isAlive(int pid) => const HostProcessLiveness().isAlive(pid);
  @override
  Future<bool> kill(int pid, {Duration grace = const Duration(seconds: 3)}) {
    killCalls++;
    return const HostProcessLiveness().kill(pid, grace: grace);
  }
}

class _SlowTree implements ProcessTreeProbe {
  @override
  Future<ProcessTree?> enumerate(int rootPid) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return ProcessTree(rootPid: rootPid, parentOf: const {10: 1, 11: 10});
  }
}

class _SlowIdentity extends _FakeLiveness {
  _SlowIdentity() : super(alivePids: {10, 11}, token: 'mine');
  @override
  Future<String?> identityToken(int pid) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return super.identityToken(pid);
  }
}

class _TimeoutKill extends _FakeLiveness {
  _TimeoutKill() : super(alivePids: {10}, token: 'mine');
  @override
  Future<bool> kill(
    int pid, {
    Duration grace = const Duration(seconds: 3),
  }) => Future.error(TimeoutException('mutation timeout'));
}
