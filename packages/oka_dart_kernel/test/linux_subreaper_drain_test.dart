import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_dart_kernel/src/gate/linux_subreaper_drain.dart';
import 'package:test/test.dart';

final class _AlwaysUnavailableProbe implements ProcessTreeProbe {
  const _AlwaysUnavailableProbe();

  @override
  Future<ProcessTree?> enumerate(int rootPid) async => null;
}

final class _SlowAliveLiveness implements ProcessLiveness {
  @override
  Future<bool> isAlive(int pid) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    return true;
  }

  @override
  Future<bool> kill(int pid, {Duration grace = const Duration(seconds: 3)}) async =>
      false;

  @override
  Future<String?> identityToken(int pid) async => 'slow-$pid';
}

final class _LateChildListingProbe implements ProcessTreeProbe {
  _LateChildListingProbe({required this.latePid, required this.revealAfter});

  final int latePid;
  final Duration revealAfter;
  final _started = Stopwatch()..start();

  @override
  Future<ProcessTree?> enumerate(int rootPid) async {
    if (_started.elapsed < revealAfter) {
      return ProcessTree(rootPid: rootPid, parentOf: {rootPid: 0});
    }
    return ProcessTree(
      rootPid: rootPid,
      parentOf: {rootPid: 0, latePid: rootPid},
    );
  }
}

void main() {
  test('directSubreaperAdoptees lists only ppid==supervisor', () {
    const tree = ProcessTree(
      rootPid: 10,
      parentOf: {10: 1, 11: 10, 12: 10, 13: 11, 14: 9},
    );
    expect(directSubreaperAdoptees(tree, 10), orderedEquals([11, 12]));
  });
  test(
    'linux drain verifies empty direct adoptees via /proc without ps',
    () async {
      final leaf = await Process.start('sleep', ['120']);
      addTearDown(() => Process.killPid(leaf.pid, ProcessSignal.sigkill));
      final result = await drainSubreaperAdoptees(
        supervisorPid: leaf.pid,
        probe: const _AlwaysUnavailableProbe(),
        budget: const Duration(milliseconds: 500),
        poll: const Duration(milliseconds: 25),
      );
      expect(result.verified, isTrue, reason: result.notes.join('; '));
      expect(result.settled, isTrue);
      expect(result.notes, isEmpty, reason: result.notes.join('; '));
    },
    skip: Platform.isLinux ? false : 'linux proc fallback',
  );

  test(
    'unavailable listing is not verified settled',
    () async {
      final result = await drainSubreaperAdoptees(
        supervisorPid: 999_999,
        probe: const _AlwaysUnavailableProbe(),
        budget: const Duration(milliseconds: 50),
      );
      expect(result.settled, isFalse);
      expect(result.verified, isFalse);
      expect(result.notes, anyElement(contains('unavailable')));
    },
    skip: Platform.isLinux ? 'linux uses /proc fallback' : false,
  );

  test(
    'adoptee appears late within budget but liveness exhausts deadline',
    () async {
      final child = await Process.start('sleep', ['120']);
      addTearDown(() => Process.killPid(child.pid, ProcessSignal.sigkill));
      final result = await drainSubreaperAdoptees(
        supervisorPid: 1,
        probe: _LateChildListingProbe(
          latePid: child.pid,
          revealAfter: const Duration(milliseconds: 20),
        ),
        liveness: _SlowAliveLiveness(),
        budget: const Duration(milliseconds: 55),
        poll: const Duration(milliseconds: 10),
      );
      expect(result.verified, isFalse);
      expect(
        result.notes,
        anyElement(contains('incomplete descendant liveness inspection')),
      );
      expect(await const HostProcessLiveness().isAlive(child.pid), isTrue);
    },
    skip: Platform.isLinux ? false : 'linux drain',
  );
}
