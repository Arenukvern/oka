// ADR-0050 refinement — a bounded run can be cancelled before its deadline.
//
// The cancellation is not a second stop path: the run keeps exactly one stop
// owner, the identity-gated tree stop the deadline already uses. These tests
// use real processes: a label-only success proves nothing about a stop.
import 'dart:async';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_core/project_operations.dart';
import 'package:test/test.dart';

void main() {
  test('a cancellation stops the real process tree, never abandons it',
      () async {
    const liveness = HostProcessLiveness();
    // A loaded machine can make the first stop incomplete: the tree stop
    // enumerates, signals and re-verifies in bounded rounds, and a saturated
    // host can exhaust them. The contract stays honest either way, so the
    // proof below requires a verified stop with no survivors and a dead root,
    // and retries a bounded number of times to get one.
    var verified = false;
    for (var attempt = 0; attempt < 3 && !verified; attempt++) {
      final cancellation = ProcessRunCancellation();
      final run = runBoundedProcess(
        'sh',
        ['-c', 'sh -c "sleep 30 & wait" & wait'],
        timeout: const Duration(seconds: 60),
        grace: const Duration(milliseconds: 1000),
        cancellation: cancellation,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      cancellation.request();
      final result = await run.timeout(const Duration(seconds: 40));
      expect(result.cause, BoundedRunCause.cancelled);
      expect(
        result.duration,
        lessThan(const Duration(seconds: 30)),
        reason: 'the cancellation must not wait for the deadline',
      );
      if (result.teardownVerified != true) {
        // An unverified stop keeps its receipt: the survivors stay named.
        expect(result.errorMessage, isNotNull);
        expect(result.survivors, isNotEmpty);
        final token = await liveness.identityToken(result.rootPid!);
        if (await verifyKillIdentity(liveness, result.rootPid!, token) ==
            KillIdentity.verified) {
          await liveness.kill(result.rootPid!, grace: Duration.zero);
        }
        continue;
      }
      verified = true;
      expect(result.survivors, isEmpty);
      expect(result.rootExitObserved, isTrue);
      expect(result.ok, isFalse);
      expect(
        await liveness.isAlive(result.rootPid!),
        isFalse,
        reason: 'the child must be verified dead, not abandoned',
      );
    }
    expect(verified, isTrue, reason: 'no verified stop was observed');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a cancellation that races the deadline still stops the tree once',
      () async {
    const liveness = HostProcessLiveness();
    final cancellation = ProcessRunCancellation();
    final run = runBoundedProcess(
      'sh',
      ['-c', 'exec sleep 30'],
      timeout: const Duration(milliseconds: 250),
      grace: const Duration(milliseconds: 200),
      cancellation: cancellation,
    );
    await Future<void>.delayed(const Duration(milliseconds: 240));
    cancellation.request();
    final result = await run.timeout(const Duration(seconds: 30));
    expect(
      result.cause,
      anyOf(BoundedRunCause.cancelled, BoundedRunCause.killedOnDeadline),
    );
    expect(result.teardownVerified, isTrue);
    expect(result.survivors, isEmpty);
    expect(await liveness.isAlive(result.rootPid!), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a cancellation before the spawn starts nothing', () async {
    final cancellation = ProcessRunCancellation()..request();
    final result = await runBoundedProcess(
      'sh',
      ['-c', 'exec sleep 30'],
      timeout: const Duration(seconds: 30),
      cancellation: cancellation,
    );
    expect(result.cause, BoundedRunCause.cancelled);
    expect(result.rootPid, isNull);
    expect(result.errorMessage, contains('before the process started'));
    expect(result.ok, isFalse);
  });

  test('a refused stop keeps the live root and reports unknown survivors',
      () async {
    const liveness = HostProcessLiveness();
    final probe = _UnavailableRootProbe();
    final cancellation = ProcessRunCancellation();
    final run = runBoundedProcess(
      'sh',
      ['-c', 'exec sleep 30'],
      timeout: const Duration(seconds: 30),
      grace: Duration.zero,
      settle: Duration.zero,
      processTreeProbe: probe,
      cancellation: cancellation,
    );
    BoundedRunResult? result;
    bool? rootAliveOnReturn;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      cancellation.request();
      result = await run.timeout(const Duration(seconds: 10));
      rootAliveOnReturn = await liveness.isAlive(result.rootPid!);
    } finally {
      // Only this fixture owns the child: reap it with a real identity
      // check, the way production recovery would.
      final root = await probe.root.future.timeout(const Duration(seconds: 5));
      final token = await liveness.identityToken(root);
      if (await verifyKillIdentity(liveness, root, token) ==
          KillIdentity.verified) {
        await liveness.kill(root, grace: Duration.zero);
      }
      await run;
    }
    expect(result.cause, BoundedRunCause.cancelled);
    expect(result.teardownVerified, isFalse);
    expect(result.rootExitObserved, isFalse);
    expect(result.exitCode, -1);
    expect(result.survivors, contains(result.rootPid));
    expect(result.errorMessage, contains('unknown'));
    expect(
      rootAliveOnReturn,
      isTrue,
      reason: 'a refused stop must expose the still-live root',
    );
    expect(await liveness.isAlive(result.rootPid!), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a controller run can be cancelled and reports the cancellation',
      () async {
    final root = await Directory.systemTemp.createTemp('project_cancel_');
    addTearDown(() => root.delete(recursive: true));
    final controller = ProjectOperationController(
      workspace: root,
      profile: const ProjectOperationProfile(
        id: 'declared',
        operations: <ProjectOperation>[
          ProjectOperation(
            id: 'check',
            kind: ProjectOperationKind.check,
            command: ProjectCommand(
              executable: 'sh',
              arguments: <String>['-c', 'exec sleep 30'],
            ),
          ),
        ],
      ),
    );
    final run = controller.run(ProjectOperationKind.check);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(controller.cancelActiveRun(), isTrue);
    final outcome = await run.timeout(const Duration(seconds: 20));
    expect(outcome.error, 'project_operation_cancelled');
    expect(outcome.physicallySettled, isTrue);
    expect(outcome.survivors, isEmpty);
    expect(outcome.ok, isFalse);
    expect(
      await const HostProcessLiveness().isAlive(outcome.pid!),
      isFalse,
      reason: 'the cancelled command must be physically stopped',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a run without a cancellation keeps the deadline behaviour', () async {
    const liveness = HostProcessLiveness();
    final result = await runBoundedProcess(
      'sh',
      ['-c', 'exec sleep 30'],
      timeout: const Duration(milliseconds: 250),
      grace: const Duration(milliseconds: 200),
    );
    expect(result.cause, BoundedRunCause.killedOnDeadline);
    expect(result.teardownVerified, isTrue);
    expect(result.survivors, isEmpty);
    expect(await liveness.isAlive(result.rootPid!), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// A probe whose discovery cannot see the process table: the stop is
/// refused, exactly as it is when the platform read fails.
class _UnavailableRootProbe implements ProcessTreeProbe {
  final root = Completer<int>();

  @override
  Future<ProcessTree?> enumerate(int rootPid) async {
    if (!root.isCompleted) root.complete(rootPid);
    return null;
  }
}
