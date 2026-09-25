import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _Handle {
  const _Handle(this.path);

  final String path;
}

final class _Liveness implements ProcessLiveness {
  const _Liveness();

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

final class _Planner implements SessionStatePlanner<_Handle> {
  const _Planner(this.root);

  final String root;

  @override
  String get id => 'snapshot-planner';

  @override
  SessionStatePlan<_Handle> plan(final SessionStateRequest request) =>
      SessionStatePlan(
        logicalResourceKey: 'snapshot:${request.sessionName}',
        namespace: SessionStateNamespace.project,
        retention: SessionStateRetention.ephemeral,
        processScope: LeaseScope.ephemeral,
        ownership: SessionStateOwnership.oka,
        acquisitionMode: SessionStateAcquisitionMode.created,
        resourceKind: SessionStateResourceKind.directory,
        rootPath: root,
        relativePath: 'profiles/${request.sessionName}',
        handle: _Handle(p.join(root, 'profiles', request.sessionName)),
      );
}

final class _Source implements SessionStateSource<_Handle> {
  const _Source();

  @override
  String get id => 'snapshot-source';

  @override
  Future<_Handle> restore(final SessionStateLease lease) async =>
      _Handle(p.join(lease.rootPath, lease.relativePath));
}

final class _CreateDirectory implements SessionStateProvisionStep<_Handle> {
  const _CreateDirectory();

  @override
  String get id => 'snapshot-create';

  @override
  Set<Artifact<Object>> get requires => const {};

  @override
  Set<Artifact<Object>> get provides => const {};

  @override
  Future<void> run(final SessionStateContext<_Handle> context) async {
    await Directory(context.handle.path).create(recursive: true);
  }
}

final class _Unused implements SessionStateInspector<_Handle> {
  const _Unused();

  @override
  String get id => 'snapshot-unused';

  @override
  Future<SessionStateFinding> inspect(
    final SessionStateContext<_Handle> context,
  ) async => const SessionStateFinding(
    inspectorId: 'snapshot-unused',
    use: SessionStateUse.unused,
    reason: 'No provider activity found.',
  );
}

SessionStateWorkflow<_Handle> _workflow(final String root) =>
    SessionStateWorkflow(
      id: 'test.process-snapshot',
      version: 1,
      plan: _Planner(root),
      source: const _Source(),
      provision: const [_CreateDirectory()],
      inspectors: const [_Unused()],
    );

void main() {
  late Directory temp;
  late SessionStateRegistry registry;
  const liveness = _Liveness();

  setUp(() async {
    temp = await Directory.systemTemp.createTemp(
      'oka-session-state-process-snapshot-',
    );
    registry = SessionStateRegistry(
      Directory(p.join(await temp.resolveSymbolicLinks(), 'registry')),
      bootId: 'test-boot',
    );
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'a process lease without a PID snapshot is unknown, never unused',
    () async {
      final workflow = _workflow(await temp.resolveSymbolicLinks());
      final lease =
          await SessionStateManager(
            registry: registry,
            liveness: liveness,
          ).acquire(
            workflow,
            SessionStateRequest(
              projectPath: temp.path,
              sessionName: 'missing-process',
            ),
          );
      final linked = await registry.update(
        lease.copyWith(processLeaseId: 'browser-process'),
        expectedGeneration: lease.generation,
      );

      expect(linked.requiresProcessSnapshot, isTrue);
      expect(linked.hasCompleteProcessSnapshot, isFalse);

      final reconciler = SessionStateReconciler(
        registry: registry,
        workflows: [workflow],
        liveness: liveness,
      );
      final inspection = await reconciler.inspectLease(leaseId: linked.id);
      final associatedFinding = inspection.entries.single.findings.singleWhere(
        (final finding) => finding.inspectorId == 'oka.associated-process',
      );
      expect(associatedFinding.use, SessionStateUse.unknown);

      final preview = await reconciler.reconcile();
      expect(
        preview.entries.single.disposition,
        SessionStateDisposition.retained,
      );
      expect(
        preview.entries.single.reason,
        contains('no durable associated-process identity snapshot'),
      );
      expect((await registry.inspect()).leases, hasLength(1));
    },
  );
}
