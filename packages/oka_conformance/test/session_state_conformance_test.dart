import 'dart:io';

import 'package:oka_conformance/oka_conformance.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _Handle {
  const _Handle(this.path);

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

final class _Planner implements SessionStatePlanner<_Handle> {
  const _Planner({
    required this.root,
    this.ownership = SessionStateOwnership.oka,
    this.acquisitionMode = SessionStateAcquisitionMode.created,
    this.retention = SessionStateRetention.ephemeral,
    this.relativePath = 'managed/profile',
  });

  final String root;
  final SessionStateOwnership ownership;
  final SessionStateAcquisitionMode acquisitionMode;
  final SessionStateRetention retention;
  final String relativePath;

  @override
  String get id => 'fixture-planner';

  @override
  SessionStatePlan<_Handle> plan(final SessionStateRequest request) =>
      SessionStatePlan(
        logicalResourceKey: 'fixture:${request.sessionName}',
        namespace: SessionStateNamespace.project,
        retention: retention,
        processScope: LeaseScope.ephemeral,
        ownership: ownership,
        acquisitionMode: acquisitionMode,
        resourceKind: SessionStateResourceKind.directory,
        rootPath: root,
        relativePath: relativePath,
        handle: _Handle(p.join(root, relativePath)),
      );
}

final class _Source implements SessionStateSource<_Handle> {
  @override
  String get id => 'fixture-source';

  @override
  Future<_Handle> restore(final SessionStateLease lease) async =>
      _Handle(p.join(lease.rootPath, lease.relativePath));
}

final class _Provision implements SessionStateProvisionStep<_Handle> {
  @override
  String get id => 'fixture-provision';

  @override
  Set<Artifact<Object>> get requires => const {};

  @override
  Set<Artifact<Object>> get provides => const {};

  @override
  Future<void> run(final SessionStateContext<_Handle> context) async {
    await File(
      p.join(context.handle.path, 'provider-data'),
    ).writeAsString('ok');
  }
}

final class _Inspector implements SessionStateInspector<_Handle> {
  const _Inspector(this.use, {this.fail = false});

  final SessionStateUse use;
  final bool fail;

  @override
  String get id => 'fixture-inspector';

  @override
  Future<SessionStateFinding> inspect(
    final SessionStateContext<_Handle> context,
  ) async {
    if (fail) throw StateError('scripted inspector failure');
    return SessionStateFinding(
      inspectorId: id,
      use: use,
      reason: 'scripted ${use.name} observation',
    );
  }
}

SessionStateWorkflow<_Handle> _workflow(
  final String root, {
  final SessionStateOwnership ownership = SessionStateOwnership.oka,
  final SessionStateAcquisitionMode acquisitionMode =
      SessionStateAcquisitionMode.created,
  final SessionStateRetention retention = SessionStateRetention.ephemeral,
  final SessionStateUse inspectorUse = SessionStateUse.unused,
  final String relativePath = 'managed/profile',
  final bool duplicateIds = false,
  final bool inspectorFails = false,
  final bool noProvision = false,
}) => SessionStateWorkflow(
  id: 'fixture-session',
  version: 1,
  plan: _Planner(
    root: root,
    ownership: ownership,
    acquisitionMode: acquisitionMode,
    retention: retention,
    relativePath: relativePath,
  ),
  source: _Source(),
  provision: [if (!noProvision) _Provision()],
  inspectors: [
    _Inspector(inspectorUse, fail: inspectorFails),
    if (duplicateIds) const _Inspector(SessionStateUse.unused),
  ],
);

void main() {
  late Directory temp;
  late Directory registryDirectory;
  late SessionStateRegistry registry;
  var nextId = 0;
  final liveness = _Liveness();

  setUp(() async {
    temp = await Directory.systemTemp.createTemp(
      'oka-session-state-conformance-',
    );
    registryDirectory = Directory(
      p.join(await temp.resolveSymbolicLinks(), 'registry'),
    );
    registry = SessionStateRegistry(
      registryDirectory,
      bootId: 'conformance-boot',
      idGenerator: () => (++nextId).toRadixString(16).padLeft(32, '0'),
    );
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'checks workflow validity and durable reserve-before-provision',
    () async {
      final workflow = _workflow(temp.path);
      final lease = await expectSessionStateProvisionConformance(
        workflow: workflow,
        request: SessionStateRequest(
          projectPath: temp.path,
          sessionName: 'managed',
        ),
        registry: registry,
        liveness: liveness,
      );

      expect(lease.phase, SessionStatePhase.ready);
      expect(
        await File(p.join(temp.path, 'managed/profile/provider-data')).exists(),
        isTrue,
      );
      expect(
        (await registry.inspect()).leases.single.phase,
        SessionStatePhase.ready,
      );
    },
  );

  test(
    'invalid workflow validation stops before provision is claimed',
    () async {
      final invalid = _workflow(temp.path, duplicateIds: true);

      await expectLater(
        expectSessionStateProvisionConformance(
          workflow: invalid,
          request: SessionStateRequest(
            projectPath: temp.path,
            sessionName: 'invalid',
          ),
          registry: registry,
          liveness: liveness,
        ),
        throwsA(isA<SessionStateConformanceException>()),
      );
      expect((await registry.inspect()).leases, isEmpty);
    },
  );

  test('workflow without stages cannot claim reservation coverage', () async {
    await expectLater(
      expectSessionStateProvisionConformance(
        workflow: _workflow(temp.path, noProvision: true),
        request: SessionStateRequest(
          projectPath: temp.path,
          sessionName: 'no-provision',
        ),
        registry: registry,
        liveness: liveness,
      ),
      throwsA(
        isA<SessionStateConformanceException>().having(
          (final error) => error.message,
          'message',
          contains('was not exercised'),
        ),
      ),
    );
    expect((await registry.inspect()).leases, isEmpty);
  });

  test(
    'busy and unknown inspector results retain the managed resource',
    () async {
      for (final (use, fails) in [
        (SessionStateUse.busy, false),
        (SessionStateUse.unknown, false),
        (SessionStateUse.unused, true),
      ]) {
        final workflow = _workflow(
          temp.path,
          inspectorUse: use,
          relativePath: 'managed/${use.name}-${fails ? 'throws' : 'returns'}',
          inspectorFails: fails,
        );
        final lease = await expectSessionStateProvisionConformance(
          workflow: workflow,
          request: SessionStateRequest(
            projectPath: temp.path,
            sessionName: '${use.name}-${fails ? 'throws' : 'returns'}',
          ),
          registry: registry,
          liveness: liveness,
        );

        final report = await expectSessionStateFailClosed(
          reconciler: SessionStateReconciler(
            registry: registry,
            workflows: [workflow],
            liveness: liveness,
          ),
          registry: registry,
          leaseId: lease.id,
        );

        expect(
          report.entries.single.disposition,
          SessionStateDisposition.retained,
        );
        expect(
          await Directory(p.join(lease.rootPath, lease.relativePath)).exists(),
          isTrue,
        );
      }
    },
  );

  test('caller-owned borrowed directory survives reconciliation', () async {
    final callerPath = Directory(p.join(temp.path, 'caller/profile'));
    await callerPath.create(recursive: true);
    await File(p.join(callerPath.path, 'existing-data')).writeAsString('keep');
    final workflow = _workflow(
      temp.path,
      ownership: SessionStateOwnership.caller,
      acquisitionMode: SessionStateAcquisitionMode.borrowed,
      relativePath: 'caller/profile',
    );

    final lease = await expectSessionStateBorrowedRetention(
      workflow: workflow,
      request: SessionStateRequest(
        projectPath: temp.path,
        sessionName: 'caller',
      ),
      registry: registry,
      liveness: liveness,
    );

    expect(lease.ownership, SessionStateOwnership.caller);
    expect(lease.acquisitionMode, SessionStateAcquisitionMode.borrowed);
    expect(
      await File(p.join(callerPath.path, 'existing-data')).exists(),
      isTrue,
    );
  });

  test('corrupt and unknown records are reported instead of hidden', () async {
    await registryDirectory.create(recursive: true);
    await File(
      p.join(registryDirectory.path, 'malformed.json'),
    ).writeAsString('{not-json');
    await File(
      p.join(registryDirectory.path, 'future.json'),
    ).writeAsString('{"schema_version":999,"id":"future"}');

    final issues = await expectSessionStateRegistryIssues(registry);
    expect(issues, hasLength(2));
    expect(
      issues.map((final issue) => issue.path),
      contains(contains('malformed')),
    );
    expect(
      issues.map((final issue) => issue.path),
      contains(contains('future')),
    );

    await expectLater(
      SessionStateManager(registry: registry, liveness: liveness).acquire(
        _workflow(temp.path),
        SessionStateRequest(projectPath: temp.path, sessionName: 'blocked'),
      ),
      throwsA(isA<SessionStateRegistryException>()),
    );
    expect(
      await Directory(p.join(temp.path, 'managed/profile')).exists(),
      isFalse,
    );
  });
}
