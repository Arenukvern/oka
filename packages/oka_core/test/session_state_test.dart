import 'dart:async';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _Handle {
  const _Handle(this.path);

  final String path;
}

final class _Liveness implements ProcessLiveness {
  _Liveness({Set<int>? livePids, Map<int, String?>? tokens})
    : livePids = livePids ?? {},
      tokens = tokens ?? {};

  final Set<int> livePids;
  final Map<int, String?> tokens;

  @override
  Future<bool> isAlive(final int pid) async => livePids.contains(pid);

  @override
  Future<String?> identityToken(final int pid) async =>
      tokens.containsKey(pid) ? tokens[pid] : 'token-$pid';

  @override
  Future<bool> kill(
    final int pid, {
    final Duration grace = const Duration(seconds: 3),
  }) async => false;
}

final class _Planner implements SessionStatePlanner<_Handle> {
  _Planner(
    this.root,
    this.retention, {
    this.relativePathPrefix = 'profiles',
    this.ownership = SessionStateOwnership.oka,
    this.acquisitionMode = SessionStateAcquisitionMode.created,
    this.resourceKind = SessionStateResourceKind.directory,
  });

  final String root;
  final SessionStateRetention retention;
  final String relativePathPrefix;
  final SessionStateOwnership ownership;
  final SessionStateAcquisitionMode acquisitionMode;
  final SessionStateResourceKind resourceKind;

  @override
  String get id => 'test-planner';

  @override
  SessionStatePlan<_Handle> plan(final SessionStateRequest request) {
    final relativePath = relativePathPrefix.isEmpty
        ? request.sessionName
        : p.join(relativePathPrefix, request.sessionName);
    return SessionStatePlan(
      logicalResourceKey: 'test:${request.sessionName}',
      namespace: SessionStateNamespace.project,
      retention: retention,
      processScope: LeaseScope.ephemeral,
      ownership: ownership,
      acquisitionMode: acquisitionMode,
      resourceKind: resourceKind,
      rootPath: root,
      relativePath: relativePath,
      handle: _Handle(p.join(root, relativePath)),
    );
  }
}

final class _Source implements SessionStateSource<_Handle> {
  @override
  String get id => 'test-source';

  @override
  Future<_Handle> restore(final SessionStateLease lease) async =>
      _Handle(p.join(lease.rootPath, lease.relativePath));
}

final class _CreateDirectory implements SessionStateProvisionStep<_Handle> {
  @override
  String get id => 'create-profile';

  @override
  Set<Artifact<Object>> get requires => const {};

  @override
  Set<Artifact<Object>> get provides => const {};

  @override
  Future<void> run(final SessionStateContext<_Handle> context) async {
    await Directory(context.handle.path).create(recursive: true);
  }
}

final class _FailProvision implements SessionStateProvisionStep<_Handle> {
  @override
  String get id => 'fail-provision';

  @override
  Set<Artifact<Object>> get requires => const {};

  @override
  Set<Artifact<Object>> get provides => const {};

  @override
  Future<void> run(final SessionStateContext<_Handle> context) {
    throw StateError('scripted provision failure');
  }
}

final class _FailOnceProvision implements SessionStateProvisionStep<_Handle> {
  bool failed = false;

  @override
  String get id => 'fail-once';

  @override
  Set<Artifact<Object>> get requires => const {};

  @override
  Set<Artifact<Object>> get provides => const {};

  @override
  Future<void> run(final SessionStateContext<_Handle> context) async {
    if (!failed) {
      failed = true;
      throw StateError('scripted first-attempt failure');
    }
    await File(p.join(context.handle.path, 'provisioned')).writeAsString('yes');
  }
}

final class _FailCleanup implements SessionStateCleanupStep<_Handle> {
  @override
  String get id => 'fail-cleanup';

  @override
  Future<void> prepare(final SessionStateContext<_Handle> context) {
    throw StateError('scripted cleanup failure');
  }
}

final class _HangingCleanup implements SessionStateCleanupStep<_Handle> {
  const _HangingCleanup(this.completion);

  final Completer<void> completion;

  @override
  String get id => 'hanging-cleanup';

  @override
  Future<void> prepare(final SessionStateContext<_Handle> context) =>
      completion.future;
}

final class _UnusedInspector implements SessionStateInspector<_Handle> {
  @override
  String get id => 'test-unused';

  @override
  Future<SessionStateFinding> inspect(
    final SessionStateContext<_Handle> context,
  ) async => const SessionStateFinding(
    inspectorId: 'test-unused',
    use: SessionStateUse.unused,
    reason: 'no active user',
  );
}

final class _UnknownInspector implements SessionStateInspector<_Handle> {
  @override
  String get id => 'test-unknown';

  @override
  Future<SessionStateFinding> inspect(
    final SessionStateContext<_Handle> context,
  ) async => const SessionStateFinding(
    inspectorId: 'test-unknown',
    use: SessionStateUse.unknown,
    reason: 'activity could not be observed',
  );
}

final class _MutableInspector implements SessionStateInspector<_Handle> {
  _MutableInspector(this.use, {this.reason = 'scripted finding'});

  SessionStateUse use;
  final String reason;

  @override
  String get id => 'mutable-inspector';

  @override
  Future<SessionStateFinding> inspect(
    final SessionStateContext<_Handle> context,
  ) async => SessionStateFinding(inspectorId: id, use: use, reason: reason);
}

final class _BusyInspector implements SessionStateInspector<_Handle> {
  @override
  String get id => 'test-busy';

  @override
  Future<SessionStateFinding> inspect(
    final SessionStateContext<_Handle> context,
  ) async => const SessionStateFinding(
    inspectorId: 'test-busy',
    use: SessionStateUse.busy,
    reason: 'resource is in use',
  );
}

final class _HangingInspector implements SessionStateInspector<_Handle> {
  const _HangingInspector(this.completion);

  final Completer<SessionStateFinding> completion;

  @override
  String get id => 'hanging-inspector';

  @override
  Future<SessionStateFinding> inspect(
    final SessionStateContext<_Handle> context,
  ) => completion.future;
}

SessionStateWorkflow<_Handle> _workflow(
  final String root, {
  final int version = 1,
  final bool failProvision = false,
  final bool failCleanup = false,
  final SessionStateRetention retention = SessionStateRetention.ephemeral,
  final SessionStateOwnership ownership = SessionStateOwnership.oka,
  final SessionStateAcquisitionMode acquisitionMode =
      SessionStateAcquisitionMode.created,
  final SessionStateResourceKind resourceKind =
      SessionStateResourceKind.directory,
  final List<SessionStateInspector<_Handle>>? inspectors,
  final List<SessionStateInspector<_Handle>>? reuseInspectors,
  final List<SessionStateProvisionStep<_Handle>>? provision,
}) => SessionStateWorkflow(
  id: 'test.profile',
  version: version,
  plan: _Planner(
    root,
    retention,
    ownership: ownership,
    acquisitionMode: acquisitionMode,
    resourceKind: resourceKind,
  ),
  source: _Source(),
  provision:
      provision ??
      [if (failProvision) _FailProvision() else _CreateDirectory()],
  inspectors: inspectors ?? [_UnusedInspector()],
  reuseInspectors: reuseInspectors,
  cleanup: [if (failCleanup) _FailCleanup()],
);

int _nextId = 0;

String _id() => (++_nextId).toRadixString(16).padLeft(32, '0');

void main() {
  late Directory temp;
  late SessionStateRegistry registry;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka-session-state-test-');
    _nextId = 0;
    registry = SessionStateRegistry(
      Directory(p.join(await temp.resolveSymbolicLinks(), 'registry')),
      bootId: 'test-boot',
      idGenerator: _id,
    );
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('creates managed directories with the host permission policy', () async {
    final lease =
        await SessionStateManager(
          registry: registry,
          liveness: _Liveness(),
        ).acquire(
          _workflow(temp.path),
          SessionStateRequest(
            projectPath: temp.path,
            sessionName: 'permissions',
          ),
        );
    final resourcePath = p.join(lease.rootPath, lease.relativePath);

    expect(
      await FileSystemEntity.type(resourcePath, followLinks: false),
      FileSystemEntityType.directory,
    );
    expect(
      await File(sessionStateOwnershipMarkerPath(resourcePath)).exists(),
      isTrue,
    );
    if (Platform.isLinux || Platform.isMacOS) {
      expect(Directory(resourcePath).statSync().mode & 0x1ff, 0x1c0);
    }
    // Windows uses the directory's inherited ACL; dart:io cannot verify it.
  });

  test('creates a managed directory on Windows without chmod', () async {
    if (!Platform.isWindows) return;
    final lease =
        await SessionStateManager(
          registry: registry,
          liveness: _Liveness(),
        ).acquire(
          _workflow(temp.path),
          SessionStateRequest(projectPath: temp.path, sessionName: 'windows'),
        );
    final resourcePath = p.join(lease.rootPath, lease.relativePath);

    expect(
      await FileSystemEntity.type(resourcePath, followLinks: false),
      FileSystemEntityType.directory,
    );
    expect(
      await File(sessionStateOwnershipMarkerPath(resourcePath)).exists(),
      isTrue,
    );
    // Directory permissions come from inherited Windows ACLs and are not
    // verified by dart:io.
  });

  test(
    'reserve before provisioning and remove orphan after affirmative checks',
    () async {
      final workflow = _workflow(temp.path);
      final manager = SessionStateManager(
        registry: registry,
        liveness: _Liveness(),
      );
      final lease = await manager.acquire(
        workflow,
        SessionStateRequest(projectPath: temp.path, sessionName: 'main'),
      );

      expect(lease.phase, SessionStatePhase.ready);
      expect(
        await Directory(p.join(temp.path, 'profiles', 'main')).exists(),
        isTrue,
      );

      final reconciler = SessionStateReconciler(
        registry: registry,
        workflows: [workflow],
        liveness: _Liveness(),
      );
      final preview = await reconciler.reconcile();
      expect(preview.applied, isFalse);
      expect(
        preview.entries.single.disposition,
        SessionStateDisposition.eligible,
      );
      expect(
        await Directory(p.join(temp.path, 'profiles', 'main')).exists(),
        isTrue,
      );

      final result = await reconciler.reconcile(apply: true);
      expect(
        result.entries.single.disposition,
        SessionStateDisposition.disposed,
      );
      expect(
        await Directory(p.join(temp.path, 'profiles', 'main')).exists(),
        isFalse,
      );
      expect((await registry.inspect()).leases, isEmpty);
    },
  );

  test(
    'does not clean a matching lease when its logical key is ambiguous',
    () async {
      final workflow = _workflow(temp.path);
      final manager = SessionStateManager(
        registry: registry,
        liveness: _Liveness(),
      );
      final lease = await manager.acquire(
        workflow,
        SessionStateRequest(projectPath: temp.path, sessionName: 'ambiguous'),
      );
      final profilePath = p.join(lease.rootPath, lease.relativePath);
      final payload = File(p.join(profilePath, 'profile-data'));
      await payload.writeAsString('keep while lease ownership is ambiguous');

      await registry.create(
        SessionStateLease.fromJson({
          ...lease.toJson(),
          'id': '00000000000000000000000000000008',
          'workflow_version': 2,
        }),
      );

      await expectLater(
        manager.acquire(
          workflow,
          SessionStateRequest(projectPath: temp.path, sessionName: 'ambiguous'),
        ),
        throwsA(
          isA<SessionStateRegistryException>().having(
            (final error) => error.message,
            'message',
            contains('multiple state leases'),
          ),
        ),
      );

      expect(
        await payload.readAsString(),
        'keep while lease ownership is ambiguous',
      );
      expect((await registry.inspect()).leases, hasLength(2));
    },
  );

  test(
    'reconciles an old lease with multiple composed workflow versions',
    () async {
      final oldWorkflow = _workflow(temp.path);
      final newWorkflow = _workflow(temp.path, version: 2, failCleanup: true);
      final lease =
          await SessionStateManager(
            registry: registry,
            liveness: _Liveness(),
          ).acquire(
            oldWorkflow,
            SessionStateRequest(
              projectPath: temp.path,
              sessionName: 'versioned',
            ),
          );

      final reconciler = SessionStateReconciler(
        registry: registry,
        workflows: [oldWorkflow, newWorkflow],
        liveness: _Liveness(),
      );
      final result = await reconciler.reconcile(apply: true);

      expect(
        result.entries.single.disposition,
        SessionStateDisposition.disposed,
      );
      expect(result.entries.single.lease.id, lease.id);
      expect((await registry.inspect()).leases, isEmpty);
      expect(
        () => SessionStateReconciler(
          registry: registry,
          workflows: [oldWorkflow, oldWorkflow],
          liveness: _Liveness(),
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'normalizes generated quarantine paths for top-level resources',
    () async {
      final workflow = SessionStateWorkflow<_Handle>(
        id: 'test.profile',
        version: 1,
        plan: _Planner(
          temp.path,
          SessionStateRetention.ephemeral,
          relativePathPrefix: '',
        ),
        source: _Source(),
        provision: [_CreateDirectory()],
        inspectors: [_UnusedInspector()],
      );
      final lease =
          await SessionStateManager(
            registry: registry,
            liveness: _Liveness(),
          ).acquire(
            workflow,
            SessionStateRequest(
              projectPath: temp.path,
              sessionName: 'top-level',
            ),
          );
      final result = await SessionStateReconciler(
        registry: registry,
        workflows: [workflow],
        liveness: _Liveness(),
      ).reconcile(apply: true);
      final quarantineRelativePath =
          result.entries.single.lease.quarantineRelativePath;

      expect(
        result.entries.single.disposition,
        SessionStateDisposition.disposed,
      );
      expect(quarantineRelativePath, '.oka-quarantine-${lease.id}');
      expect(quarantineRelativePath!.split('/'), isNot(contains('.')));
      expect(
        await Directory(p.join(lease.rootPath, lease.relativePath)).exists(),
        isFalse,
      );
    },
  );

  test('reacquiring Oka-owned state records reused provenance', () async {
    final request = SessionStateRequest(
      projectPath: temp.path,
      sessionName: 'persistent',
    );
    final manager = SessionStateManager(
      registry: registry,
      liveness: _Liveness(),
    );
    final createdWorkflow = _workflow(
      temp.path,
      retention: SessionStateRetention.persistent,
    );
    final created = await manager.acquire(createdWorkflow, request);
    expect(created.acquisitionMode, SessionStateAcquisitionMode.created);
    expect(created.ownership, SessionStateOwnership.oka);

    final reusedWorkflow = _workflow(
      temp.path,
      retention: SessionStateRetention.persistent,
      acquisitionMode: SessionStateAcquisitionMode.reused,
    );
    expect(reusedWorkflow.validate(), isEmpty);
    final reused = await manager.acquire(reusedWorkflow, request);

    expect(reused.id, created.id);
    expect(reused.acquisitionMode, SessionStateAcquisitionMode.reused);
    expect(reused.ownership, SessionStateOwnership.oka);

    final reacquired = await manager.acquire(createdWorkflow, request);
    expect(reacquired.id, created.id);
    expect(reacquired.acquisitionMode, SessionStateAcquisitionMode.reused);
    expect(reacquired.ownership, SessionStateOwnership.oka);
  });

  test(
    'reacquires the exact ephemeral lease when cleanup is unknown but reuse is safe',
    () async {
      final cleanupInspector = _MutableInspector(
        SessionStateUse.unknown,
        reason: 'stale SingletonLock remains; cleanup cannot prove safety',
      );
      final workflow = _workflow(
        temp.path,
        inspectors: [cleanupInspector],
        reuseInspectors: [_UnusedInspector()],
      );
      final request = SessionStateRequest(
        projectPath: temp.path,
        sessionName: 'stale-lock',
      );
      final manager = SessionStateManager(
        registry: registry,
        liveness: _Liveness(),
      );
      final created = await manager.acquire(workflow, request);
      final content = File(
        p.join(created.rootPath, created.relativePath, 'profile-data'),
      );
      await content.writeAsString('preserve this profile');
      final associated = await manager.attachProcess(
        leaseId: created.id,
        processLeaseId: 'stale-chrome-process',
        processPid: 48291,
        processPidToken: 'token-48291',
      );

      final cleanupPreview = await SessionStateReconciler(
        registry: registry,
        workflows: [workflow],
        liveness: _Liveness(),
      ).reconcile();
      expect(
        cleanupPreview.entries.single.disposition,
        SessionStateDisposition.retained,
      );
      expect(await content.readAsString(), 'preserve this profile');

      final reused = await manager.acquire(workflow, request);

      expect(reused.id, created.id);
      expect(reused.phase, SessionStatePhase.ready);
      expect(reused.acquisitionMode, SessionStateAcquisitionMode.reused);
      expect(reused.processLeaseId, isNull);
      expect(reused.processPid, isNull);
      expect(reused.processPidToken, isNull);
      expect(reused.metadata['process_snapshot_required'], isFalse);
      expect(await content.readAsString(), 'preserve this profile');
      expect(associated.processPid, 48291);

      await manager.expectProcess(reused.id);
      await manager.attachProcess(
        leaseId: reused.id,
        processLeaseId: 'clean-shutdown-process',
        processPid: 48292,
        processPidToken: 'token-48292',
      );
      cleanupInspector.use = SessionStateUse.unused;
      final cleanup = await SessionStateReconciler(
        registry: registry,
        workflows: [workflow],
        liveness: _Liveness(),
      ).reconcile(apply: true);

      expect(
        cleanup.entries.single.disposition,
        SessionStateDisposition.disposed,
      );
      expect(await content.exists(), isFalse);
      expect((await registry.inspect()).leases, isEmpty);
    },
  );

  test(
    'ephemeral reuse blocks missing inspectors, uncertain activity, borrowed state, and unfinished leases',
    () async {
      final manager = SessionStateManager(
        registry: registry,
        liveness: _Liveness(),
      );

      for (final scenario in [
        (
          name: 'no-reuse-inspector',
          reuse: null,
          phase: SessionStatePhase.ready,
          ownership: SessionStateOwnership.oka,
        ),
        (
          name: 'reuse-unknown',
          reuse: <SessionStateInspector<_Handle>>[
            _MutableInspector(SessionStateUse.unknown),
          ],
          phase: SessionStatePhase.ready,
          ownership: SessionStateOwnership.oka,
        ),
        (
          name: 'reuse-busy',
          reuse: <SessionStateInspector<_Handle>>[_BusyInspector()],
          phase: SessionStatePhase.ready,
          ownership: SessionStateOwnership.oka,
        ),
        (
          name: 'partial',
          reuse: <SessionStateInspector<_Handle>>[_UnusedInspector()],
          phase: SessionStatePhase.partial,
          ownership: SessionStateOwnership.oka,
        ),
        (
          name: 'quarantined',
          reuse: <SessionStateInspector<_Handle>>[_UnusedInspector()],
          phase: SessionStatePhase.quarantined,
          ownership: SessionStateOwnership.oka,
        ),
        (
          name: 'borrowed',
          reuse: <SessionStateInspector<_Handle>>[_UnusedInspector()],
          phase: SessionStatePhase.ready,
          ownership: SessionStateOwnership.caller,
        ),
      ]) {
        final name = scenario.name;
        final ownership = scenario.ownership;
        final acquisitionMode = ownership == SessionStateOwnership.caller
            ? SessionStateAcquisitionMode.borrowed
            : SessionStateAcquisitionMode.created;
        final profile = Directory(p.join(temp.path, 'profiles', name));
        if (ownership == SessionStateOwnership.caller) {
          await profile.create(recursive: true);
        }
        final workflow = _workflow(
          temp.path,
          ownership: ownership,
          acquisitionMode: acquisitionMode,
          inspectors: [_UnknownInspector()],
          reuseInspectors: scenario.reuse,
          provision: ownership == SessionStateOwnership.caller
              ? const []
              : null,
        );
        final request = SessionStateRequest(
          projectPath: temp.path,
          sessionName: name,
        );
        final created = await manager.acquire(workflow, request);
        if (scenario.phase != SessionStatePhase.ready) {
          await registry.update(
            created.copyWith(phase: scenario.phase),
            expectedGeneration: created.generation,
          );
        }
        await expectLater(
          manager.acquire(workflow, request),
          throwsA(isA<SessionStateRegistryException>()),
          reason: name,
        );
        expect(await profile.exists(), isTrue, reason: name);
        final retained = await registry.read(created.id);
        expect(retained, isNotNull, reason: name);
        expect(retained!.phase, scenario.phase, reason: name);
      }
    },
  );

  test(
    'ephemeral reuse requires intact Oka ownership and reservation markers',
    () async {
      for (final tamperReservation in [false, true]) {
        final workflow = _workflow(
          temp.path,
          inspectors: [_UnknownInspector()],
          reuseInspectors: [_UnusedInspector()],
        );
        final request = SessionStateRequest(
          projectPath: temp.path,
          sessionName: 'marker-$tamperReservation',
        );
        final manager = SessionStateManager(
          registry: registry,
          liveness: _Liveness(),
        );
        final lease = await manager.acquire(workflow, request);
        final directory = Directory(p.join(lease.rootPath, lease.relativePath));
        final ownershipMarker = File(
          sessionStateOwnershipMarkerPath(directory.path),
        );
        final reservationMarker = File(lease.reservationMarkerPath);
        if (tamperReservation) {
          await reservationMarker.writeAsString('not the lease marker');
        } else {
          await ownershipMarker.writeAsString('not the lease marker');
        }

        await expectLater(
          manager.acquire(workflow, request),
          throwsA(isA<SessionStateRegistryException>()),
        );
        expect(await directory.exists(), isTrue);
        expect(
          await (tamperReservation ? reservationMarker : ownershipMarker)
              .exists(),
          isTrue,
        );
      }
    },
  );

  test(
    'ephemeral reuse blocks incomplete associated-process identity',
    () async {
      final workflow = _workflow(
        temp.path,
        inspectors: [_UnknownInspector()],
        reuseInspectors: [_UnusedInspector()],
      );
      final manager = SessionStateManager(
        registry: registry,
        liveness: _Liveness(),
      );
      final request = SessionStateRequest(
        projectPath: temp.path,
        sessionName: 'missing-process-token',
      );
      final lease = await manager.acquire(workflow, request);
      await manager.attachProcess(
        leaseId: lease.id,
        processLeaseId: 'process-without-token',
        processPid: 73942,
        processPidToken: null,
      );

      await expectLater(
        manager.acquire(workflow, request),
        throwsA(isA<SessionStateRegistryException>()),
      );
      final retained = await registry.read(lease.id);
      expect(retained!.processPid, 73942);
      expect(retained.processPidToken, isNull);
    },
  );

  test(
    'reuse inspectors override reconciliation inspectors only on reacquire',
    () async {
      final baseWorkflow = _workflow(
        temp.path,
        retention: SessionStateRetention.persistent,
      );
      final workflow = SessionStateWorkflow<_Handle>(
        id: baseWorkflow.id,
        version: baseWorkflow.version,
        plan: baseWorkflow.plan,
        source: baseWorkflow.source,
        provision: baseWorkflow.provision,
        inspectors: [_BusyInspector()],
        reuseInspectors: [_UnusedInspector()],
      );
      final manager = SessionStateManager(
        registry: registry,
        liveness: _Liveness(),
      );
      final request = SessionStateRequest(
        projectPath: temp.path,
        sessionName: 'inspector-overrides',
      );
      final first = await manager.acquire(workflow, request);
      final reacquired = await manager.acquire(workflow, request);

      expect(reacquired.id, first.id);
      final regularSession = await workflow.restoreSession(reacquired);
      final regularFindings = await regularSession.inspect(reacquired);
      final reuseSession = await workflow.restoreSession(
        reacquired,
        forReuse: true,
      );
      final reuseFindings = await reuseSession.inspect(reacquired);
      expect(regularFindings.single.use, SessionStateUse.busy);
      expect(reuseFindings.single.use, SessionStateUse.unused);
    },
  );

  test(
    'reacquiring caller-owned state keeps its borrowed provenance',
    () async {
      final borrowedPath = Directory(p.join(temp.path, 'profiles', 'borrowed'));
      await borrowedPath.create(recursive: true);
      final workflow = _workflow(
        temp.path,
        retention: SessionStateRetention.persistent,
        ownership: SessionStateOwnership.caller,
        acquisitionMode: SessionStateAcquisitionMode.borrowed,
      );
      final manager = SessionStateManager(
        registry: registry,
        liveness: _Liveness(),
      );
      final request = SessionStateRequest(
        projectPath: temp.path,
        sessionName: 'borrowed',
      );

      final first = await manager.acquire(workflow, request);
      final second = await manager.acquire(workflow, request);

      expect(first.acquisitionMode, SessionStateAcquisitionMode.borrowed);
      expect(second.acquisitionMode, SessionStateAcquisitionMode.borrowed);
      expect(second.ownership, SessionStateOwnership.caller);
      expect(await borrowedPath.exists(), isTrue);
      expect(await File(first.reservationMarkerPath).exists(), isFalse);
      expect(await File(second.reservationMarkerPath).exists(), isFalse);
    },
  );

  test(
    'reacquiring an Oka opaque resource does not write filesystem markers',
    () async {
      final workflow = _workflow(
        temp.path,
        retention: SessionStateRetention.persistent,
        resourceKind: SessionStateResourceKind.opaque,
        provision: const [],
      );
      final manager = SessionStateManager(
        registry: registry,
        liveness: _Liveness(),
      );
      final request = SessionStateRequest(
        projectPath: temp.path,
        sessionName: 'opaque-avd',
      );

      final created = await manager.acquire(workflow, request);
      final reused = await manager.acquire(workflow, request);

      expect(reused.id, created.id);
      expect(reused.acquisitionMode, SessionStateAcquisitionMode.reused);
      expect(await File(created.reservationMarkerPath).exists(), isFalse);
      expect(
        await File(
          sessionStateOwnershipMarkerPath(
            p.join(created.rootPath, created.relativePath),
          ),
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'reconciles a crash before the reservation marker without deleting a resource',
    () async {
      final workflow = _workflow(temp.path);
      final lease =
          await SessionStateManager(
            registry: registry,
            liveness: _Liveness(),
          ).acquire(
            workflow,
            SessionStateRequest(
              projectPath: temp.path,
              sessionName: 'unstarted',
            ),
          );
      await File(lease.reservationMarkerPath).delete();
      await Directory(
        p.join(lease.rootPath, lease.relativePath),
      ).delete(recursive: true);
      final reserved = await registry.update(
        lease.copyWith(phase: SessionStatePhase.reserved),
        expectedGeneration: lease.generation,
      );
      expect(await File(reserved.reservationMarkerPath).exists(), isFalse);
      expect(reserved.phase, SessionStatePhase.reserved);

      final reconciler = SessionStateReconciler(
        registry: registry,
        workflows: [workflow],
        liveness: _Liveness(),
      );
      final preview = await reconciler.reconcile();

      expect(
        preview.entries.single.disposition,
        SessionStateDisposition.eligible,
      );
      expect(preview.entries.single.resourceMissing, isTrue);
      expect(
        preview.entries.single.reason,
        contains('no marker and no resource'),
      );
      expect((await registry.inspect()).leases, hasLength(1));

      final result = await reconciler.reconcile(apply: true);

      expect(
        result.entries.single.disposition,
        SessionStateDisposition.disposed,
      );
      expect(result.entries.single.resourceMissing, isTrue);
      expect((await registry.inspect()).leases, isEmpty);
    },
  );

  test('provision failure retains a durable partial lease', () async {
    final workflow = _workflow(temp.path, failProvision: true);
    final manager = SessionStateManager(
      registry: registry,
      liveness: _Liveness(),
    );

    await expectLater(
      manager.acquire(
        workflow,
        SessionStateRequest(projectPath: temp.path, sessionName: 'failed'),
      ),
      throwsA(isA<SessionStateProvisionException>()),
    );

    final snapshot = await registry.inspect();
    expect(snapshot.issues, isEmpty);
    expect(snapshot.leases.single.phase, SessionStatePhase.partial);
    expect(
      snapshot.leases.single.lastError,
      contains('scripted provision failure'),
    );
    expect(
      await Directory(p.join(temp.path, 'profiles', 'failed')).exists(),
      isTrue,
    );

    final reconciler = SessionStateReconciler(
      registry: registry,
      workflows: [workflow],
      liveness: _Liveness(),
    );
    final cleanup = await reconciler.reconcile(apply: true);

    expect(
      cleanup.entries.single.disposition,
      SessionStateDisposition.disposed,
    );
    expect(
      await Directory(p.join(temp.path, 'profiles', 'failed')).exists(),
      isFalse,
    );
    expect((await registry.inspect()).leases, isEmpty);
  });

  test('resumes a failed idempotent provision to ready', () async {
    final step = _FailOnceProvision();
    final workflow = SessionStateWorkflow<_Handle>(
      id: 'test.profile',
      version: 1,
      plan: _Planner(temp.path, SessionStateRetention.ephemeral),
      source: _Source(),
      provision: [step],
      inspectors: [_UnusedInspector()],
    );
    final manager = SessionStateManager(
      registry: registry,
      liveness: _Liveness(),
    );
    await expectLater(
      manager.acquire(
        workflow,
        SessionStateRequest(projectPath: temp.path, sessionName: 'resume'),
      ),
      throwsA(isA<SessionStateProvisionException>()),
    );
    final partial = (await registry.inspect()).leases.single;
    final resourceDirectory = Directory(
      p.join(partial.rootPath, partial.relativePath),
    );
    if (Platform.isLinux || Platform.isMacOS) {
      await Process.run('chmod', ['755', resourceDirectory.path]);
    }

    final resumed = await manager.resume(workflow, partial.id);

    expect(resumed.phase, SessionStatePhase.ready);
    expect(resumed.attemptCount, 1);
    expect(resumed.lastError, isNull);
    expect(
      await File(
        p.join(temp.path, 'profiles', 'resume', 'provisioned'),
      ).readAsString(),
      'yes',
    );
    if (Platform.isLinux || Platform.isMacOS) {
      expect(resourceDirectory.statSync().mode & 0x1ff, 0x1c0);
    }
  });

  test('resume refuses busy and unknown inspector findings', () async {
    final failing = _workflow(temp.path, failProvision: true);
    final manager = SessionStateManager(
      registry: registry,
      liveness: _Liveness(),
    );
    await expectLater(
      manager.acquire(
        failing,
        SessionStateRequest(projectPath: temp.path, sessionName: 'not-unused'),
      ),
      throwsA(isA<SessionStateProvisionException>()),
    );
    final partial = (await registry.inspect()).leases.single;

    for (final inspector in [_BusyInspector(), _UnknownInspector()]) {
      final workflow = SessionStateWorkflow<_Handle>(
        id: failing.id,
        version: failing.version,
        plan: failing.plan,
        source: failing.source,
        provision: failing.provision,
        inspectors: [inspector],
      );
      await expectLater(
        manager.resume(workflow, partial.id),
        throwsA(isA<SessionStateRegistryException>()),
      );
      expect(
        (await registry.read(partial.id))?.phase,
        SessionStatePhase.partial,
      );
    }
    await expectLater(
      manager.resume(failing, partial.id),
      throwsA(isA<SessionStateProvisionException>()),
    );
    final stillPartial = await registry.read(partial.id);
    expect(stillPartial?.phase, SessionStatePhase.partial);
    expect(stillPartial?.attemptCount, 2);
  });

  test('resume refuses a live associated process identity', () async {
    final workflow = _workflow(temp.path, failProvision: true);
    await expectLater(
      SessionStateManager(registry: registry, liveness: _Liveness()).acquire(
        workflow,
        SessionStateRequest(
          projectPath: temp.path,
          sessionName: 'associated-live',
        ),
      ),
      throwsA(isA<SessionStateProvisionException>()),
    );
    final partial = (await registry.inspect()).leases.single;
    final associated = await registry.update(
      partial.copyWith(
        processLeaseId: 'associated-process',
        processPid: 4242,
        processPidToken: 'associated-token',
      ),
      expectedGeneration: partial.generation,
    );

    await expectLater(
      SessionStateManager(
        registry: registry,
        liveness: _Liveness(
          livePids: {4242},
          tokens: {4242: 'associated-token'},
        ),
      ).resume(workflow, associated.id),
      throwsA(
        isA<SessionStateRegistryException>().having(
          (final error) => error.message,
          'message',
          contains('still used by recorded process'),
        ),
      ),
    );
    expect(
      (await registry.read(associated.id))?.phase,
      SessionStatePhase.partial,
    );
  });

  test(
    'resume refuses a live previous owner and mismatched workflow',
    () async {
      final workflow = _workflow(temp.path, failProvision: true);
      await expectLater(
        SessionStateManager(registry: registry, liveness: _Liveness()).acquire(
          workflow,
          SessionStateRequest(
            projectPath: temp.path,
            sessionName: 'wrong-owner',
          ),
        ),
        throwsA(isA<SessionStateProvisionException>()),
      );
      final partial = (await registry.inspect()).leases.single;
      final liveOwner = await registry.update(
        partial.copyWith(ownerPid: 4242, ownerPidToken: 'owner-token'),
        expectedGeneration: partial.generation,
      );

      await expectLater(
        SessionStateManager(
          registry: registry,
          liveness: _Liveness(livePids: {4242}, tokens: {4242: 'owner-token'}),
        ).resume(workflow, liveOwner.id),
        throwsA(
          isA<SessionStateRegistryException>().having(
            (final error) => error.message,
            'message',
            contains('live Oka process'),
          ),
        ),
      );

      final mismatchedWorkflow = SessionStateWorkflow<_Handle>(
        id: 'test.other',
        version: workflow.version,
        plan: workflow.plan,
        source: workflow.source,
        provision: workflow.provision,
        inspectors: workflow.inspectors,
      );
      await expectLater(
        SessionStateManager(
          registry: registry,
          liveness: _Liveness(),
        ).resume(mismatchedWorkflow, liveOwner.id),
        throwsA(
          isA<SessionStateRegistryException>().having(
            (final error) => error.message,
            'message',
            contains('not test.other@1'),
          ),
        ),
      );
      expect(
        (await registry.read(liveOwner.id))?.phase,
        SessionStatePhase.partial,
      );
    },
  );

  test(
    'resume rejects ready leases and only restores an empty unmarked dir',
    () async {
      final workflow = _workflow(temp.path);
      final manager = SessionStateManager(
        registry: registry,
        liveness: _Liveness(),
      );
      final ready = await manager.acquire(
        workflow,
        SessionStateRequest(
          projectPath: temp.path,
          sessionName: 'already-ready',
        ),
      );
      await expectLater(
        manager.resume(workflow, ready.id),
        throwsA(
          isA<SessionStateRegistryException>().having(
            (final error) => error.message,
            'message',
            contains('cannot be resumed from phase "ready"'),
          ),
        ),
      );

      final withMissingInnerMarker = await manager.acquire(
        workflow,
        SessionStateRequest(
          projectPath: temp.path,
          sessionName: 'empty-recovery',
        ),
      );
      final resourcePath = p.join(
        withMissingInnerMarker.rootPath,
        withMissingInnerMarker.relativePath,
      );
      await File(sessionStateOwnershipMarkerPath(resourcePath)).delete();
      final partial = await registry.update(
        withMissingInnerMarker.copyWith(phase: SessionStatePhase.partial),
        expectedGeneration: withMissingInnerMarker.generation,
      );
      final resumed = await manager.resume(workflow, partial.id);
      expect(resumed.phase, SessionStatePhase.ready);
      expect(
        await File(sessionStateOwnershipMarkerPath(resourcePath)).exists(),
        isTrue,
      );

      final nonempty = await manager.acquire(
        workflow,
        SessionStateRequest(
          projectPath: temp.path,
          sessionName: 'nonempty-recovery',
        ),
      );
      final nonemptyPath = p.join(nonempty.rootPath, nonempty.relativePath);
      await File(sessionStateOwnershipMarkerPath(nonemptyPath)).delete();
      await File(p.join(nonemptyPath, 'data')).writeAsString('preserve me');
      final nonemptyPartial = await registry.update(
        nonempty.copyWith(phase: SessionStatePhase.partial),
        expectedGeneration: nonempty.generation,
      );
      await expectLater(
        manager.resume(workflow, nonemptyPartial.id),
        throwsA(
          isA<SessionStateRegistryException>().having(
            (final error) => error.message,
            'message',
            contains('existing directory is not empty'),
          ),
        ),
      );

      final withoutReservation = await manager.acquire(
        workflow,
        SessionStateRequest(
          projectPath: temp.path,
          sessionName: 'missing-reservation',
        ),
      );
      await File(withoutReservation.reservationMarkerPath).delete();
      final unproven = await registry.update(
        withoutReservation.copyWith(phase: SessionStatePhase.partial),
        expectedGeneration: withoutReservation.generation,
      );
      await expectLater(
        manager.resume(workflow, unproven.id),
        throwsA(
          isA<SessionStateRegistryException>().having(
            (final error) => error.message,
            'message',
            contains('reservation marker'),
          ),
        ),
      );
    },
  );

  test(
    'reports future-schema records instead of silently dropping them',
    () async {
      await registry.directory.create(recursive: true);
      await File(
        p.join(registry.directory.path, 'future.json'),
      ).writeAsString('{"schema_version":99}');

      final snapshot = await registry.inspect();

      expect(snapshot.leases, isEmpty);
      expect(snapshot.issues, hasLength(1));
      expect(
        snapshot.issues.single.message,
        contains('Unsupported session-state schema'),
      );
    },
  );

  test(
    'reports records with unknown fields rather than rewriting them',
    () async {
      await registry.directory.create(recursive: true);
      await File(
        p.join(registry.directory.path, 'future.json'),
      ).writeAsString('{"schema_version":1,"future_ownership":"caller"}');

      final snapshot = await registry.inspect();

      expect(snapshot.leases, isEmpty);
      expect(snapshot.issues, hasLength(1));
      expect(snapshot.issues.single.message, contains('unknown field'));
    },
  );

  test(
    'refuses to initialize a registry reached through a symbolic link',
    () async {
      if (Platform.isWindows) return;
      final target = Directory(p.join(temp.path, 'redirected-registry'));
      await target.create();
      await Link(registry.directory.path).create(target.path);

      await expectLater(
        registry.hostIdentity(),
        throwsA(isA<SessionStateRegistryException>()),
      );
      expect(File(p.join(target.path, 'host.json')).existsSync(), isFalse);
    },
  );

  test(
    'keeps the registry directory owner-only across lock acquisitions',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;

      await registry.hostIdentity();
      await registry.withResourceLock('test-resource', () async {});

      final stat = await FileStat.stat(registry.directory.path);
      expect(stat.mode & 0x1ff, 0x1c0); // 0700
    },
  );

  test('records a Windows boot identity when running on Windows', () async {
    if (!Platform.isWindows) return;
    final windowsRegistry = SessionStateRegistry(
      Directory(p.join(temp.path, 'windows-registry')),
    );

    final identity = await windowsRegistry.hostIdentity();

    expect(identity.hostId, isNotEmpty);
    expect(identity.bootId, startsWith('windows-'));
  });

  test('keeps directory cleanup report-only on Windows', () async {
    if (!Platform.isWindows) return;
    final now = DateTime.now().toUtc();
    await registry.create(
      SessionStateLease(
        id: '00000000000000000000000000000001',
        workflowId: 'test.profile',
        workflowVersion: 1,
        logicalResourceKey: 'test:windows-report-only',
        namespace: SessionStateNamespace.project,
        retention: SessionStateRetention.ephemeral,
        processScope: LeaseScope.ephemeral,
        ownership: SessionStateOwnership.oka,
        acquisitionMode: SessionStateAcquisitionMode.created,
        phase: SessionStatePhase.ready,
        resourceKind: SessionStateResourceKind.directory,
        rootPath: temp.path,
        relativePath: 'profiles/windows',
        markerNonce: 'test-marker',
        hostId: 'test-host',
        bootId: 'test-boot',
        ownerProject: temp.path,
        ownerPid: pid,
        ownerPidToken: 'test-process',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final workflow = _workflow(temp.path);
    final reconciler = SessionStateReconciler(
      registry: registry,
      workflows: [workflow],
      liveness: _Liveness(),
    );

    final report = await reconciler.reconcile(apply: true);

    expect(report.entries.single.disposition, SessionStateDisposition.retained);
    expect(
      report.entries.single.reason,
      contains('Windows cleanup is report-only'),
    );
    expect((await registry.inspect()).leases, hasLength(1));
  });

  test('rejects a path traversal before writing a reservation', () async {
    final workflow = _workflow(temp.path);
    final manager = SessionStateManager(
      registry: registry,
      liveness: _Liveness(),
    );

    await expectLater(
      manager.acquire(
        workflow,
        SessionStateRequest(projectPath: temp.path, sessionName: '../outside'),
      ),
      throwsA(isA<ArgumentError>()),
    );

    expect((await registry.inspect()).leases, isEmpty);
    expect(await Directory(p.join(temp.path, 'outside')).exists(), isFalse);
  });

  test(
    'rejects a symlinked state ancestor without touching its target',
    () async {
      if (Platform.isWindows) return;
      final root = Directory(p.join(temp.path, 'state-root'));
      final outside = Directory(p.join(temp.path, 'outside'));
      await root.create();
      await outside.create();
      final sentinel = File(p.join(outside.path, 'keep.txt'));
      await sentinel.writeAsString('caller data');
      await Link(p.join(root.path, 'profiles')).create(outside.path);
      final workflow = _workflow(root.path);
      final manager = SessionStateManager(
        registry: registry,
        liveness: _Liveness(),
      );

      await expectLater(
        manager.acquire(
          workflow,
          SessionStateRequest(projectPath: temp.path, sessionName: 'linked'),
        ),
        throwsA(isA<SessionStateRegistryException>()),
      );

      expect((await registry.inspect()).leases, isEmpty);
      expect(await sentinel.readAsString(), 'caller data');
      expect(await Directory(p.join(outside.path, 'linked')).exists(), isFalse);
    },
  );

  test('retains state if its ownership marker no longer matches', () async {
    final workflow = _workflow(temp.path);
    final lease =
        await SessionStateManager(
          registry: registry,
          liveness: _Liveness(),
        ).acquire(
          workflow,
          SessionStateRequest(projectPath: temp.path, sessionName: 'marker'),
        );
    final marker = File(
      sessionStateOwnershipMarkerPath(
        p.join(lease.rootPath, lease.relativePath),
      ),
    );
    await marker.writeAsString(
      '{"id":"${lease.id}","nonce":"wrong","host_id":"${lease.hostId}"}',
    );
    final reconciler = SessionStateReconciler(
      registry: registry,
      workflows: [workflow],
      liveness: _Liveness(),
    );

    final result = await reconciler.reconcile(apply: true);

    expect(result.entries.single.disposition, SessionStateDisposition.retained);
    expect(result.entries.single.reason, contains('ownership marker'));
    expect(
      await Directory(p.join(lease.rootPath, lease.relativePath)).exists(),
      isTrue,
    );
    expect((await registry.inspect()).leases, hasLength(1));
  });

  test(
    'retains rather than treating an unavailable root as a missing resource',
    () async {
      final stateRoot = Directory(p.join(temp.path, 'state-root'));
      await stateRoot.create();
      final workflow = _workflow(stateRoot.path);
      final lease =
          await SessionStateManager(
            registry: registry,
            liveness: _Liveness(),
          ).acquire(
            workflow,
            SessionStateRequest(
              projectPath: temp.path,
              sessionName: 'unmounted',
            ),
          );
      final movedRoot = Directory(p.join(temp.path, 'moved-state-root'));
      await stateRoot.rename(movedRoot.path);
      final reconciler = SessionStateReconciler(
        registry: registry,
        workflows: [workflow],
        liveness: _Liveness(),
      );

      final result = await reconciler.reconcile(apply: true);

      expect(
        result.entries.single.disposition,
        SessionStateDisposition.retained,
      );
      expect(result.entries.single.reason, contains('root is unavailable'));
      expect(
        await Directory(p.join(movedRoot.path, lease.relativePath)).exists(),
        isTrue,
      );
      expect((await registry.inspect()).leases, hasLength(1));
    },
  );

  test('serializes concurrent acquisition of one logical resource', () async {
    final workflow = _workflow(temp.path);
    final manager = SessionStateManager(
      registry: registry,
      liveness: _Liveness(),
    );
    Future<Object> acquire() async {
      try {
        return await manager.acquire(
          workflow,
          SessionStateRequest(projectPath: temp.path, sessionName: 'raced'),
        );
      } on Object catch (error) {
        return error;
      }
    }

    final outcomes = await Future.wait([acquire(), acquire()]);

    expect(outcomes.whereType<SessionStateLease>(), hasLength(1));
    expect(outcomes.whereType<SessionStateRegistryException>(), hasLength(1));
    expect((await registry.inspect()).leases, hasLength(1));
  });

  test(
    'rejects stale registry generations without overwriting newer state',
    () async {
      final workflow = _workflow(temp.path);
      final lease =
          await SessionStateManager(
            registry: registry,
            liveness: _Liveness(),
          ).acquire(
            workflow,
            SessionStateRequest(projectPath: temp.path, sessionName: 'cas'),
          );
      final updated = await registry.update(
        lease.copyWith(lastError: 'current writer'),
        expectedGeneration: lease.generation,
      );

      await expectLater(
        registry.update(
          lease.copyWith(lastError: 'stale writer'),
          expectedGeneration: lease.generation,
        ),
        throwsA(isA<SessionStateRegistryException>()),
      );

      final current = await registry.read(lease.id);
      expect(updated.generation, lease.generation + 1);
      expect(current?.lastError, 'current writer');
    },
  );

  test(
    'reaps abandoned atomic-write temp files under the registry lock',
    () async {
      final workflow = _workflow(temp.path);
      final lease =
          await SessionStateManager(
            registry: registry,
            liveness: _Liveness(),
          ).acquire(
            workflow,
            SessionStateRequest(
              projectPath: temp.path,
              sessionName: 'temp-reap',
            ),
          );
      final recordTemp = File(
        p.join(registry.directory.path, '.${lease.id}.${_id()}.tmp'),
      );
      final hostTemp = File(
        p.join(registry.directory.path, '.host.${_id()}.tmp'),
      );
      await recordTemp.writeAsString('incomplete record');
      await hostTemp.writeAsString('incomplete host record');

      await registry.update(
        lease.copyWith(lastError: 'updated'),
        expectedGeneration: lease.generation,
      );

      expect(await recordTemp.exists(), isFalse);
      expect(await hostTemp.exists(), isFalse);
    },
  );

  test('rechecks concurrent reconciliations under the resource lock', () async {
    final workflow = _workflow(temp.path);
    final lease =
        await SessionStateManager(
          registry: registry,
          liveness: _Liveness(),
        ).acquire(
          workflow,
          SessionStateRequest(
            projectPath: temp.path,
            sessionName: 'cleanup-race',
          ),
        );
    final secondRegistry = SessionStateRegistry(
      registry.directory,
      bootId: 'test-boot',
      idGenerator: _id,
    );
    final firstReconciler = SessionStateReconciler(
      registry: registry,
      workflows: [workflow],
      liveness: _Liveness(),
    );
    final secondReconciler = SessionStateReconciler(
      registry: secondRegistry,
      workflows: [workflow],
      liveness: _Liveness(),
    );

    final reports = await Future.wait([
      firstReconciler.reconcile(apply: true),
      secondReconciler.reconcile(apply: true),
    ]);

    expect(
      reports
          .expand((final report) => report.entries)
          .where(
            (final entry) => entry.disposition == SessionStateDisposition.error,
          ),
      isEmpty,
    );
    expect(
      await Directory(p.join(lease.rootPath, lease.relativePath)).exists(),
      isFalse,
    );
    expect((await registry.inspect()).leases, isEmpty);
  });

  test('retains state when the recorded boot identity differs', () async {
    final workflow = _workflow(temp.path);
    final lease =
        await SessionStateManager(
          registry: registry,
          liveness: _Liveness(),
        ).acquire(
          workflow,
          SessionStateRequest(
            projectPath: temp.path,
            sessionName: 'boot-mismatch',
          ),
        );
    final otherBootRegistry = SessionStateRegistry(
      registry.directory,
      bootId: 'different-boot',
      idGenerator: _id,
    );
    final reconciler = SessionStateReconciler(
      registry: otherBootRegistry,
      workflows: [workflow],
      liveness: _Liveness(),
    );

    final result = await reconciler.reconcile(apply: true);

    expect(result.entries.single.disposition, SessionStateDisposition.retained);
    expect(result.entries.single.reason, contains('host or boot identity'));
    expect(
      await Directory(p.join(lease.rootPath, lease.relativePath)).exists(),
      isTrue,
    );
    expect((await registry.inspect()).leases, hasLength(1));

    final closed = await reconciler.close(leaseId: lease.id, apply: true);
    expect(closed.entries.single.disposition, SessionStateDisposition.disposed);
    expect(
      await Directory(p.join(lease.rootPath, lease.relativePath)).exists(),
      isFalse,
    );
    expect((await registry.inspect()).leases, isEmpty);
  });

  test(
    'persistent reacquisition refreshes boot binding without dropping process identity',
    () async {
      final workflow = _workflow(
        temp.path,
        retention: SessionStateRetention.persistent,
      );
      final manager = SessionStateManager(
        registry: registry,
        liveness: _Liveness(),
      );
      final request = SessionStateRequest(
        projectPath: temp.path,
        sessionName: 'persistent-reboot',
      );
      final lease = await manager.acquire(workflow, request);
      final attached = await manager.attachProcess(
        leaseId: lease.id,
        processLeaseId: 'browser-process',
        processPid: 4242,
        processPidToken: 'browser-token',
      );
      final legacyLayout = await registry.update(
        attached.copyWith(reservationMarkerAdjacent: false),
        expectedGeneration: attached.generation,
      );
      final nextBootRegistry = SessionStateRegistry(
        registry.directory,
        bootId: 'next-test-boot',
        idGenerator: _id,
      );

      final reused = await SessionStateManager(
        registry: nextBootRegistry,
        liveness: _Liveness(),
      ).acquire(workflow, request);

      expect(reused.id, lease.id);
      expect(reused.bootId, 'next-test-boot');
      expect(reused.reservationMarkerAdjacent, isTrue);
      expect(reused.processPid, legacyLayout.processPid);
      expect(reused.processPidToken, legacyLayout.processPidToken);
    },
  );

  test('persistent reacquisition refuses a live previous Oka owner', () async {
    final workflow = _workflow(
      temp.path,
      retention: SessionStateRetention.persistent,
    );
    final original =
        await SessionStateManager(
          registry: registry,
          liveness: _Liveness(),
        ).acquire(
          workflow,
          SessionStateRequest(
            projectPath: temp.path,
            sessionName: 'single-writer',
          ),
        );
    final reserved = await registry.update(
      original.copyWith(ownerPid: 4242, ownerPidToken: 'active-owner-token'),
      expectedGeneration: original.generation,
    );
    final liveness = _Liveness(
      livePids: {4242},
      tokens: {4242: 'active-owner-token'},
    );

    await expectLater(
      SessionStateManager(registry: registry, liveness: liveness).acquire(
        workflow,
        SessionStateRequest(
          projectPath: temp.path,
          sessionName: 'single-writer',
        ),
      ),
      throwsA(
        isA<SessionStateRegistryException>().having(
          (final error) => error.message,
          'message',
          contains('live Oka process'),
        ),
      ),
    );
    expect((await registry.read(reserved.id))?.ownerPid, 4242);
  });

  test('refuses cleanup when a spawned process snapshot is missing', () async {
    final workflow = _workflow(temp.path);
    final lease =
        await SessionStateManager(
          registry: registry,
          liveness: _Liveness(),
        ).acquire(
          workflow,
          SessionStateRequest(
            projectPath: temp.path,
            sessionName: 'missing-pid',
          ),
        );
    final expectedProcessLease = await registry.update(
      lease.copyWith(
        metadata: {...lease.metadata, 'process_snapshot_required': true},
      ),
      expectedGeneration: lease.generation,
    );
    await Directory(
      p.join(expectedProcessLease.rootPath, expectedProcessLease.relativePath),
    ).delete(recursive: true);
    final reconciler = SessionStateReconciler(
      registry: registry,
      workflows: [workflow],
      liveness: _Liveness(),
    );

    final report = await reconciler.reconcile(apply: true);

    expect(report.entries.single.disposition, SessionStateDisposition.retained);
    expect(
      report.entries.single.reason,
      contains('no durable associated-process'),
    );
    expect(
      await Directory(
        p.join(
          expectedProcessLease.rootPath,
          expectedProcessLease.relativePath,
        ),
      ).exists(),
      isFalse,
    );
    expect((await registry.inspect()).leases.single.id, lease.id);
  });

  test(
    'retains an explicitly closed lease while its owning process is live',
    () async {
      final liveness = _Liveness();
      final workflow = _workflow(temp.path);
      final lease =
          await SessionStateManager(
            registry: registry,
            liveness: liveness,
          ).acquire(
            workflow,
            SessionStateRequest(
              projectPath: temp.path,
              sessionName: 'live-owner',
            ),
          );
      liveness.livePids.add(lease.ownerPid);

      final report = await SessionStateReconciler(
        registry: registry,
        workflows: [workflow],
        liveness: liveness,
      ).close(leaseId: lease.id, apply: true);

      expect(
        report.entries.single.disposition,
        SessionStateDisposition.retained,
      );
      expect(report.entries.single.reason, contains('owning Oka process'));
      expect(
        await Directory(p.join(lease.rootPath, lease.relativePath)).exists(),
        isTrue,
      );
    },
  );

  test('retains state while the matching associated process is live', () async {
    final liveness = _Liveness();
    final workflow = _workflow(temp.path);
    final manager = SessionStateManager(registry: registry, liveness: liveness);
    final lease = await manager.acquire(
      workflow,
      SessionStateRequest(
        projectPath: temp.path,
        sessionName: 'live-associated-process',
      ),
    );
    await manager.attachProcess(
      leaseId: lease.id,
      processLeaseId: 'test-process-lease',
      processPid: 4242,
      processPidToken: 'browser-token',
    );
    liveness
      ..livePids.add(4242)
      ..tokens[4242] = 'browser-token';

    final report = await SessionStateReconciler(
      registry: registry,
      workflows: [workflow],
      liveness: liveness,
    ).reconcile(apply: true);

    expect(report.entries.single.disposition, SessionStateDisposition.retained);
    expect(report.entries.single.reason, contains('associated process'));
  });

  test(
    'a reused PID with a different identity is not the leased process',
    () async {
      final liveness = _Liveness();
      final workflow = _workflow(temp.path);
      final manager = SessionStateManager(
        registry: registry,
        liveness: liveness,
      );
      final lease = await manager.acquire(
        workflow,
        SessionStateRequest(
          projectPath: temp.path,
          sessionName: 'recycled-pid',
        ),
      );
      await manager.attachProcess(
        leaseId: lease.id,
        processLeaseId: 'test-process-lease',
        processPid: 4242,
        processPidToken: 'old-browser-token',
      );
      liveness
        ..livePids.add(4242)
        ..tokens[4242] = 'new-process-token';

      final report = await SessionStateReconciler(
        registry: registry,
        workflows: [workflow],
        liveness: liveness,
      ).reconcile(apply: true);

      expect(
        report.entries.single.disposition,
        SessionStateDisposition.disposed,
      );
      expect(
        await Directory(p.join(lease.rootPath, lease.relativePath)).exists(),
        isFalse,
      );
    },
  );

  test(
    'retains state when an active PID has no verifiable identity token',
    () async {
      final liveness = _Liveness();
      final workflow = _workflow(temp.path);
      final manager = SessionStateManager(
        registry: registry,
        liveness: liveness,
      );
      final lease = await manager.acquire(
        workflow,
        SessionStateRequest(
          projectPath: temp.path,
          sessionName: 'unknown-token',
        ),
      );
      await manager.attachProcess(
        leaseId: lease.id,
        processLeaseId: 'test-process-lease',
        processPid: 4242,
        processPidToken: 'browser-token',
      );
      liveness
        ..livePids.add(4242)
        ..tokens[4242] = null;

      final report = await SessionStateReconciler(
        registry: registry,
        workflows: [workflow],
        liveness: liveness,
      ).reconcile(apply: true);

      expect(
        report.entries.single.disposition,
        SessionStateDisposition.retained,
      );
      expect(report.entries.single.reason, contains('identity is unknown'));
    },
  );

  test('an unknown provider inspector vetoes cleanup', () async {
    final workflow = SessionStateWorkflow<_Handle>(
      id: 'test.unknown-inspector',
      version: 1,
      plan: _Planner(temp.path, SessionStateRetention.ephemeral),
      source: _Source(),
      provision: [_CreateDirectory()],
      inspectors: [_UnknownInspector()],
    );
    final lease =
        await SessionStateManager(
          registry: registry,
          liveness: _Liveness(),
        ).acquire(
          workflow,
          SessionStateRequest(projectPath: temp.path, sessionName: 'unknown'),
        );
    final reconciler = SessionStateReconciler(
      registry: registry,
      workflows: [workflow],
      liveness: _Liveness(),
    );

    final result = await reconciler.reconcile(apply: true);

    expect(result.entries.single.disposition, SessionStateDisposition.retained);
    expect(
      result.entries.single.reason,
      contains('activity could not be observed'),
    );
    expect(
      await Directory(p.join(lease.rootPath, lease.relativePath)).exists(),
      isTrue,
    );
    expect((await registry.inspect()).leases, hasLength(1));
  });

  test('quarantines repeated cleanup failures for explicit retry', () async {
    final workflow = _workflow(temp.path, failCleanup: true);
    final lease =
        await SessionStateManager(
          registry: registry,
          liveness: _Liveness(),
        ).acquire(
          workflow,
          SessionStateRequest(projectPath: temp.path, sessionName: 'stuck'),
        );
    final reconciler = SessionStateReconciler(
      registry: registry,
      workflows: [workflow],
      liveness: _Liveness(),
    );

    for (
      var attempt = 0;
      attempt < SessionStateReconciler.maxCleanupAttempts;
      attempt++
    ) {
      await reconciler.reconcile(apply: true);
    }
    final quarantined = (await registry.inspect()).leases.single;
    expect(quarantined.phase, SessionStatePhase.quarantined);
    expect(quarantined.attemptCount, SessionStateReconciler.maxCleanupAttempts);
    expect(quarantined.lastError, contains('scripted cleanup failure'));

    final automaticRetry = await reconciler.reconcile(apply: true);
    expect(
      automaticRetry.entries.single.disposition,
      SessionStateDisposition.retained,
    );
    expect(automaticRetry.entries.single.reason, contains('retry explicitly'));
    expect(
      (await registry.inspect()).leases.single.attemptCount,
      SessionStateReconciler.maxCleanupAttempts,
    );

    final explicitRetry = await reconciler.close(
      leaseId: lease.id,
      apply: true,
    );
    expect(
      explicitRetry.entries.single.disposition,
      SessionStateDisposition.error,
    );
    expect(
      (await registry.inspect()).leases.single.attemptCount,
      SessionStateReconciler.maxCleanupAttempts + 1,
    );
  });

  test('refuses to reconcile persistent state automatically', () async {
    final workflow = _workflow(
      temp.path,
      retention: SessionStateRetention.persistent,
    );
    final lease =
        await SessionStateManager(
          registry: registry,
          liveness: _Liveness(),
        ).acquire(
          workflow,
          SessionStateRequest(
            projectPath: temp.path,
            sessionName: 'persistent',
          ),
        );
    final reconciler = SessionStateReconciler(
      registry: registry,
      workflows: [workflow],
      liveness: _Liveness(),
    );

    final inspection = await reconciler.inspectLease(leaseId: lease.id);
    expect(
      inspection.entries.single.disposition,
      SessionStateDisposition.retained,
    );
    expect(
      inspection.entries.single.findings.map(
        (final finding) => finding.inspectorId,
      ),
      contains('test-unused'),
    );
    expect(
      inspection.entries.single.reason,
      contains('no cleanup was attempted'),
    );

    final report = await reconciler.reconcile(apply: true);

    expect(report.entries.single.disposition, SessionStateDisposition.retained);
    expect(report.entries.single.reason, contains('retention is persistent'));
    expect((await registry.inspect()).leases, hasLength(1));

    final closePreview = await reconciler.close(leaseId: lease.id);
    expect(closePreview.applied, isFalse);
    expect(
      closePreview.entries.single.disposition,
      SessionStateDisposition.eligible,
    );
    expect(
      await Directory(p.join(temp.path, 'profiles', 'persistent')).exists(),
      isTrue,
    );

    final closed = await reconciler.close(leaseId: lease.id, apply: true);
    expect(closed.entries.single.disposition, SessionStateDisposition.disposed);
    expect((await registry.inspect()).leases, isEmpty);
  });

  test(
    'reconciles a stopped ephemeral acquisition before re-acquiring it',
    () async {
      final workflow = _workflow(temp.path);
      final manager = SessionStateManager(
        registry: registry,
        liveness: _Liveness(),
      );
      final first = await manager.acquire(
        workflow,
        SessionStateRequest(projectPath: temp.path, sessionName: 'repeat'),
      );

      final second = await manager.acquire(
        workflow,
        SessionStateRequest(projectPath: temp.path, sessionName: 'repeat'),
      );

      expect(second.id, isNot(first.id));
      final resource = p.join(second.rootPath, second.relativePath);
      expect(await Directory(resource).exists(), isTrue);
      final ownerMarker = await File(
        sessionStateOwnershipMarkerPath(resource),
      ).readAsString();
      expect(ownerMarker, contains(second.id));
      expect(ownerMarker, isNot(contains(first.id)));
      expect(
        await Directory(
          p.join(
            second.rootPath,
            p.dirname(second.relativePath),
            '.oka-quarantine-${first.id}',
          ),
        ).exists(),
        isFalse,
      );
      expect((await registry.inspect()).leases.single.id, second.id);
    },
  );

  test(
    'forget removes only the record and refuses a present resource',
    () async {
      final workflow = _workflow(temp.path);
      final lease =
          await SessionStateManager(
            registry: registry,
            liveness: _Liveness(),
          ).acquire(
            workflow,
            SessionStateRequest(projectPath: temp.path, sessionName: 'forget'),
          );
      final reconciler = SessionStateReconciler(
        registry: registry,
        workflows: [workflow],
        liveness: _Liveness(),
      );
      final resource = Directory(p.join(lease.rootPath, lease.relativePath));

      final blocked = await reconciler.forget(leaseId: lease.id, apply: true);
      expect(
        blocked.entries.single.disposition,
        SessionStateDisposition.retained,
      );
      expect(await resource.exists(), isTrue);
      expect((await registry.inspect()).leases, hasLength(1));

      await resource.delete(recursive: true);
      final reservation = File(lease.reservationMarkerPath);
      expect(await reservation.exists(), isTrue);

      final forgotten = await reconciler.forget(leaseId: lease.id, apply: true);

      expect(
        forgotten.entries.single.disposition,
        SessionStateDisposition.forgotten,
      );
      expect(await reservation.exists(), isTrue);
      expect((await registry.inspect()).leases, isEmpty);
    },
  );

  test('inspector timeout is unknown and retains the state', () async {
    final completion = Completer<SessionStateFinding>();
    final workflow = SessionStateWorkflow<_Handle>(
      id: 'test.hanging-inspector',
      version: 1,
      plan: _Planner(temp.path, SessionStateRetention.ephemeral),
      source: _Source(),
      provision: [_CreateDirectory()],
      inspectors: [_HangingInspector(completion)],
      inspectionTimeout: const Duration(milliseconds: 1),
    );
    final lease =
        await SessionStateManager(
          registry: registry,
          liveness: _Liveness(),
        ).acquire(
          workflow,
          SessionStateRequest(
            projectPath: temp.path,
            sessionName: 'inspect-timeout',
          ),
        );
    final reconciler = SessionStateReconciler(
      registry: registry,
      workflows: [workflow],
      liveness: _Liveness(),
    );

    final report = await reconciler.reconcile(apply: true);

    expect(report.entries.single.disposition, SessionStateDisposition.retained);
    expect(report.entries.single.reason, contains('exceeded 1ms'));
    expect((await registry.inspect()).leases.single.id, lease.id);
    completion.complete(
      const SessionStateFinding(
        inspectorId: 'hanging-inspector',
        use: SessionStateUse.unused,
        reason: 'late completion',
      ),
    );
  });

  test(
    'cleanup timeout records the active cleanup process and partial state',
    () async {
      final completion = Completer<void>();
      final workflow = SessionStateWorkflow<_Handle>(
        id: 'test.hanging-cleanup',
        version: 1,
        plan: _Planner(temp.path, SessionStateRetention.ephemeral),
        source: _Source(),
        provision: [_CreateDirectory()],
        inspectors: [_UnusedInspector()],
        cleanup: [_HangingCleanup(completion)],
        cleanupTimeout: const Duration(milliseconds: 1),
      );
      final lease =
          await SessionStateManager(
            registry: registry,
            liveness: _Liveness(),
          ).acquire(
            workflow,
            SessionStateRequest(
              projectPath: temp.path,
              sessionName: 'cleanup-timeout',
            ),
          );
      await registry.update(
        lease.copyWith(
          ownerPid: pid + 1000000,
          ownerPidToken: 'original-owner',
        ),
        expectedGeneration: lease.generation,
      );
      final reconciler = SessionStateReconciler(
        registry: registry,
        workflows: [workflow],
        liveness: _Liveness(),
      );

      final report = await reconciler.reconcile(apply: true);
      final current = (await registry.inspect()).leases.single;

      expect(report.entries.single.disposition, SessionStateDisposition.error);
      expect(current.phase, SessionStatePhase.partial);
      expect(current.lastError, contains('TimeoutException'));
      expect(current.ownerPid, pid);
      expect(current.ownerPid, isNot(pid + 1000000));
      completion.complete();
    },
  );

  test('current-user registry refuses a missing home instead of using cwd', () {
    expect(
      () => SessionStateRegistry.forCurrentUser(homeDirectory: ''),
      throwsA(isA<SessionStateRegistryException>()),
    );
  });
}
