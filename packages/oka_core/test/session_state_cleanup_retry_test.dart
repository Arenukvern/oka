import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _ProfileHandle {
  const _ProfileHandle(this.path);

  final String path;
}

final class _Liveness implements ProcessLiveness {
  @override
  Future<bool> isAlive(final int pid) async => false;

  @override
  Future<String?> identityToken(final int pid) async => 'token-$pid';

  @override
  Future<bool> kill(
    final int pid, {
    final Duration grace = const Duration(seconds: 3),
  }) async => false;
}

final class _Planner implements SessionStatePlanner<_ProfileHandle> {
  const _Planner(this.root);

  final String root;

  @override
  String get id => 'cleanup-retry-planner';

  @override
  SessionStatePlan<_ProfileHandle> plan(final SessionStateRequest request) =>
      SessionStatePlan(
        logicalResourceKey: 'cleanup-retry:${request.sessionName}',
        namespace: SessionStateNamespace.project,
        retention: SessionStateRetention.ephemeral,
        processScope: LeaseScope.ephemeral,
        ownership: SessionStateOwnership.oka,
        acquisitionMode: SessionStateAcquisitionMode.created,
        resourceKind: SessionStateResourceKind.directory,
        rootPath: root,
        relativePath: 'profiles/${request.sessionName}',
        handle: _ProfileHandle(p.join(root, 'profiles', request.sessionName)),
      );
}

final class _Source implements SessionStateSource<_ProfileHandle> {
  @override
  String get id => 'cleanup-retry-source';

  @override
  Future<_ProfileHandle> restore(final SessionStateLease lease) async =>
      _ProfileHandle(p.join(lease.rootPath, lease.relativePath));
}

final class _CreateProfile
    implements SessionStateProvisionStep<_ProfileHandle> {
  @override
  String get id => 'create-profile';

  @override
  Set<Artifact<Object>> get requires => const {};

  @override
  Set<Artifact<Object>> get provides => const {};

  @override
  Future<void> run(final SessionStateContext<_ProfileHandle> context) async {
    await Directory(context.handle.path).create(recursive: true);
  }
}

final class _UnusedInspector implements SessionStateInspector<_ProfileHandle> {
  @override
  String get id => 'cleanup-retry-unused';

  @override
  Future<SessionStateFinding> inspect(
    final SessionStateContext<_ProfileHandle> context,
  ) async => const SessionStateFinding(
    inspectorId: 'cleanup-retry-unused',
    use: SessionStateUse.unused,
    reason: 'the test profile has no active user.',
  );
}

final class _JournaledCleanup
    implements SessionStateCleanupStep<_ProfileHandle> {
  @override
  String get id => 'journaled-cleanup';

  @override
  Future<void> prepare(
    final SessionStateContext<_ProfileHandle> context,
  ) async {
    final evidenceDirectory = Directory(
      p.join(context.lease.rootPath, '.cleanup-retry-evidence'),
    );
    await evidenceDirectory.create(recursive: true);
    final runs = File(p.join(evidenceDirectory.path, 'journaled-cleanup-runs'));
    final runCount = await runs.exists()
        ? int.parse(await runs.readAsString())
        : 0;
    await runs.writeAsString('${runCount + 1}', flush: true);
  }
}

final class _FailOnceDurableCleanup
    implements SessionStateCleanupStep<_ProfileHandle> {
  @override
  String get id => 'fail-once-durable-cleanup';

  @override
  Future<void> prepare(
    final SessionStateContext<_ProfileHandle> context,
  ) async {
    final evidenceDirectory = Directory(
      p.join(context.lease.rootPath, '.cleanup-retry-evidence'),
    );
    await evidenceDirectory.create(recursive: true);
    final attempts = File(p.join(evidenceDirectory.path, 'cleanup-attempts'));
    final attempt =
        (await attempts.exists()
            ? int.parse(await attempts.readAsString())
            : 0) +
        1;
    await attempts.writeAsString('$attempt', flush: true);
    if (attempt == 1) {
      throw StateError('scripted first cleanup preparation failure');
    }
    await File(
      p.join(evidenceDirectory.path, 'cleanup-prepared'),
    ).writeAsString('yes', flush: true);
  }
}

SessionStateWorkflow<_ProfileHandle> _workflow(final String root) =>
    SessionStateWorkflow(
      id: 'test.cleanup-retry',
      version: 1,
      plan: _Planner(root),
      source: _Source(),
      provision: [_CreateProfile()],
      inspectors: [_UnusedInspector()],
      cleanup: [_JournaledCleanup(), _FailOnceDurableCleanup()],
    );

int _nextId = 0;

String _id() => (++_nextId).toRadixString(16).padLeft(32, '0');

void main() {
  late Directory temp;
  late Directory registryDirectory;
  late SessionStateRegistry registry;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp(
      'oka-session-state-cleanup-retry-',
    );
    _nextId = 0;
    registryDirectory = Directory(
      p.join(await temp.resolveSymbolicLinks(), 'registry'),
    );
    registry = SessionStateRegistry(
      registryDirectory,
      bootId: 'cleanup-retry-test-boot',
      idGenerator: _id,
    );
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'retries durable cleanup preparation without rerunning journaled steps',
    () async {
      final workflow = _workflow(temp.path);
      final liveness = _Liveness();
      final lease =
          await SessionStateManager(
            registry: registry,
            liveness: liveness,
          ).acquire(
            workflow,
            SessionStateRequest(projectPath: temp.path, sessionName: 'main'),
          );

      expect(lease.phase, SessionStatePhase.ready);
      expect(lease.reservationMarkerAdjacent, isTrue);
      expect(await File(lease.reservationMarkerPath).exists(), isTrue);
      final marker =
          jsonDecode(await File(lease.reservationMarkerPath).readAsString())
              as Map;
      expect(marker['id'], lease.id);
      expect(marker['nonce'], lease.markerNonce);
      expect(marker['host_id'], lease.hostId);

      final initialReconciler = SessionStateReconciler(
        registry: registry,
        workflows: [workflow],
        liveness: liveness,
      );
      final preview = await initialReconciler.reconcile();
      expect(
        preview.entries.single.disposition,
        SessionStateDisposition.eligible,
      );
      expect(
        preview.entries.single.findings,
        contains(
          isA<SessionStateFinding>()
              .having(
                (final finding) => finding.inspectorId,
                'inspector',
                'cleanup-retry-unused',
              )
              .having(
                (final finding) => finding.use,
                'use',
                SessionStateUse.unused,
              ),
        ),
      );
      final firstAttempt = await initialReconciler.reconcile(apply: true);
      expect(
        firstAttempt.entries.single.disposition,
        SessionStateDisposition.error,
      );
      expect(
        firstAttempt.entries.single.lease.phase,
        SessionStatePhase.partial,
      );
      expect(firstAttempt.entries.single.lease.completedCleanupSteps, [
        'journaled-cleanup',
      ]);
      expect(
        firstAttempt.entries.single.lease.lastError,
        contains('scripted first cleanup preparation failure'),
      );
      expect(
        firstAttempt.entries.single.findings,
        contains(
          isA<SessionStateFinding>()
              .having(
                (final finding) => finding.inspectorId,
                'inspector',
                'cleanup-retry-unused',
              )
              .having(
                (final finding) => finding.use,
                'use',
                SessionStateUse.unused,
              ),
        ),
      );

      final durablePartial = (await registry.inspect()).leases.single;
      expect(durablePartial.phase, SessionStatePhase.partial);
      expect(durablePartial.completedCleanupSteps, ['journaled-cleanup']);
      expect(durablePartial.attemptCount, 1);
      expect(
        await File(
          p.join(
            lease.rootPath,
            '.cleanup-retry-evidence',
            'journaled-cleanup-runs',
          ),
        ).readAsString(),
        '1',
      );
      expect(
        await File(
          p.join(lease.rootPath, '.cleanup-retry-evidence', 'cleanup-attempts'),
        ).readAsString(),
        '1',
      );

      // Reopen the on-disk registry to exercise retry from its durable journal.
      final recoveredRegistry = SessionStateRegistry(
        registryDirectory,
        bootId: 'cleanup-retry-test-boot',
      );
      final recoveredPartial = await recoveredRegistry.read(lease.id);
      expect(recoveredPartial?.phase, SessionStatePhase.partial);
      expect(recoveredPartial?.completedCleanupSteps, ['journaled-cleanup']);

      final retry = await SessionStateReconciler(
        registry: recoveredRegistry,
        workflows: [_workflow(temp.path)],
        liveness: liveness,
      ).reconcile(apply: true);

      expect(
        retry.entries.single.disposition,
        SessionStateDisposition.disposed,
      );
      expect(retry.entries.single.lease.phase, SessionStatePhase.disposed);
      expect(retry.entries.single.lease.completedCleanupSteps, [
        'journaled-cleanup',
        'fail-once-durable-cleanup',
      ]);
      expect(
        retry.entries.single.findings,
        contains(
          isA<SessionStateFinding>()
              .having(
                (final finding) => finding.inspectorId,
                'inspector',
                'cleanup-retry-unused',
              )
              .having(
                (final finding) => finding.use,
                'use',
                SessionStateUse.unused,
              ),
        ),
      );
      expect(
        await File(
          p.join(
            lease.rootPath,
            '.cleanup-retry-evidence',
            'journaled-cleanup-runs',
          ),
        ).readAsString(),
        '1',
      );
      expect(
        await File(
          p.join(lease.rootPath, '.cleanup-retry-evidence', 'cleanup-attempts'),
        ).readAsString(),
        '2',
      );
      expect(
        await File(
          p.join(lease.rootPath, '.cleanup-retry-evidence', 'cleanup-prepared'),
        ).readAsString(),
        'yes',
      );
      expect(
        await recoveredRegistry.inspect().then((final s) => s.leases),
        isEmpty,
      );
    },
  );
}
