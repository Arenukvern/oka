import 'dart:io';

import 'package:oka/oka.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String project;
  late CacheTransactions transactions;

  setUp(() async {
    final created = await Directory.systemTemp.createTemp('oka-cache-api-');
    temp = Directory(await created.resolveSymbolicLinks());
    project = p.join(temp.path, 'project');
    final output = File(p.join(project, '.oka_cache', 'build', 'web', 'app'));
    await output.parent.create(recursive: true);
    await output.writeAsString('artifact');
    transactions = CacheTransactions(
      workspaces: CacheWorkspaceRepository(
        environment: {
          'HOME': p.join(temp.path, 'home'),
          'OKA_CACHE': p.join(temp.path, 'shared'),
        },
        currentDirectory: temp.path,
        sessionStates: _sessionStates(const SessionStateRegistrySnapshot()),
      ),
      clock: () => DateTime.utc(2026, 9, 22),
    );
  });

  tearDown(() => temp.delete(recursive: true));

  test('preview save and apply are usable without CLI or stdout', () async {
    final request = CacheWorkspaceRequest(projectPath: project);
    final workspace = await transactions.workspaces.read(request);
    final preview = await transactions.preview(
      workspace,
      const CacheCleanupRequest(scopes: {'build'}),
    );
    expect(preview.selected, hasLength(1));

    final planPath = p.join(temp.path, 'reviewed.json');
    await transactions.savePlan(planPath, workspace, preview);
    final applied = await transactions.applySavedPlan(planPath);
    expect(applied.errors, isEmpty);
    expect(applied.deleted, hasLength(1));
  });

  test('inspect uses one measured snapshot for cleanup totals', () async {
    final result = await transactions.inspect(
      CacheWorkspaceRequest(projectPath: project),
      const CacheInspectRequest(),
    );
    expect(result.storage.totalBytes, greaterThanOrEqualTo(8));
    expect(result.cleanup.selectedBytes, 8);
  });

  test(
    'missing session-state home disables pruning without throwing',
    () async {
      final protectedLocation = StorageLocation(
        id: 'project-build',
        path: p.join(project, '.oka_cache', 'build'),
        category: 'build',
        platform: 'fixture',
        ownership: 'oka',
        prunable: true,
        scope: 'build',
      );
      final repository = CacheWorkspaceRepository(
        environment: const {'HOME': ''},
        currentDirectory: temp.path,
        projects: _Projects(),
        locations:
            ({
              required projectPath,
              required environment,
              required includeShared,
              required includeProject,
              required liveness,
              toolGuidance = const [],
            }) async => [protectedLocation],
      );

      final workspace = await repository.read(
        CacheWorkspaceRequest(projectPath: project),
      );

      expect(workspace.complete, isFalse);
      expect(
        workspace.warnings,
        contains(contains('Could not inspect session-state registry')),
      );
      expect(workspace.inventory.locations.single.prunable, isFalse);
    },
  );

  test(
    'registered session-state resources protect overlapping cache paths',
    () async {
      final cacheBuild = p.join(project, '.oka_cache', 'build');
      final resource = p.join(cacheBuild, 'session-profile');
      await Directory(resource).create(recursive: true);
      await File(p.join(resource, 'cookie')).writeAsString('preserve');
      final cacheLocation = StorageLocation(
        id: 'project-build',
        path: cacheBuild,
        category: 'build',
        platform: 'fixture',
        ownership: 'oka',
        prunable: true,
        scope: 'build',
      );
      final repository = CacheWorkspaceRepository(
        environment: {'HOME': p.join(temp.path, 'home')},
        currentDirectory: temp.path,
        sessionStates: _sessionStates(
          SessionStateRegistrySnapshot(
            leases: [_lease(cacheBuild, 'session-profile')],
          ),
        ),
        locations:
            ({
              required projectPath,
              required environment,
              required includeShared,
              required includeProject,
              required liveness,
              toolGuidance = const [],
            }) async => [cacheLocation],
      );

      final workspace = await repository.read(
        CacheWorkspaceRequest(projectPath: project),
      );
      final observed = await workspace.inventory.scan();
      expect(
        observed.locations.any(
          (measurement) =>
              measurement.location.category == 'managed-session-state',
        ),
        isTrue,
      );
      final result = await workspace.inventory.prune(
        scopes: {'build'},
        apply: true,
      );

      expect(result.selected, isEmpty);
      expect(result.deleted, isEmpty);
      expect(File(p.join(resource, 'cookie')).existsSync(), isTrue);

      final cleared = await workspace.inventory.applyPlan(
        StorageCleanupPlan(
          selected: [
            StorageMeasurement(
              location: cacheLocation,
              sizeBytes: 7,
              fileCount: 1,
              modifiedAt: DateTime.now(),
              complete: true,
              warnings: const [],
            ),
          ],
        ),
      );
      expect(cleared.deleted, isEmpty);
      expect(cleared.errors, contains(contains('protected')));
      expect(File(p.join(resource, 'cookie')).existsSync(), isTrue);
    },
  );

  test('prune preserves a disposing lease quarantine path', () async {
    final cacheBuild = p.join(project, '.oka_cache', 'build');
    final quarantine = Directory(
      p.join(cacheBuild, 'state', '.oka-quarantine-fixture'),
    );
    await quarantine.create(recursive: true);
    final payload = File(p.join(quarantine.path, 'profile-data'));
    await payload.writeAsString('preserve until disposal completes');
    final topLevelQuarantine = Directory(
      p.join(cacheBuild, '.oka-quarantine-top-level'),
    );
    await topLevelQuarantine.create(recursive: true);
    final topLevelPayload = File(
      p.join(topLevelQuarantine.path, 'profile-data'),
    );
    await topLevelPayload.writeAsString('preserve normalized quarantine');
    final cacheLocation = StorageLocation(
      id: 'project-build',
      path: cacheBuild,
      category: 'build',
      platform: 'fixture',
      ownership: 'oka',
      prunable: true,
      scope: 'build',
    );
    final repository = CacheWorkspaceRepository(
      environment: {'HOME': p.join(temp.path, 'home')},
      currentDirectory: temp.path,
      sessionStates: _sessionStates(
        SessionStateRegistrySnapshot(
          leases: [
            _lease(
              cacheBuild,
              'state/profile',
              phase: SessionStatePhase.disposing,
              quarantineRelativePath: 'state/.oka-quarantine-fixture',
            ),
            _lease(
              cacheBuild,
              'top-level-profile',
              phase: SessionStatePhase.disposing,
              quarantineRelativePath: '.oka-quarantine-top-level',
            ),
          ],
        ),
      ),
      locations:
          ({
            required projectPath,
            required environment,
            required includeShared,
            required includeProject,
            required liveness,
            toolGuidance = const [],
          }) async => [cacheLocation],
    );

    final workspace = await repository.read(
      CacheWorkspaceRequest(projectPath: project),
    );
    final result = await workspace.inventory.prune(
      scopes: {'build'},
      apply: true,
    );

    expect(workspace.complete, isTrue, reason: workspace.warnings.join('\n'));
    expect(
      workspace.inventory.protectedPaths,
      contains(p.normalize(quarantine.path)),
    );
    expect(
      workspace.inventory.protectedPaths,
      contains(p.normalize(topLevelQuarantine.path)),
    );
    expect(result.selected, isEmpty);
    expect(result.deleted, isEmpty);
    expect(payload.existsSync(), isTrue);
    expect(topLevelPayload.existsSync(), isTrue);
  });

  test('unsafe persisted quarantine path disables pruning', () async {
    final cacheBuild = p.join(project, '.oka_cache', 'build');
    final linked = Link(p.join(cacheBuild, 'linked'));
    final external = Directory(p.join(temp.path, 'external'));
    await external.create();
    await linked.create(external.path);
    final payload = File(p.join(cacheBuild, 'output'));
    await payload.writeAsString('retain on uncertain protection');
    final cacheLocation = StorageLocation(
      id: 'project-build',
      path: cacheBuild,
      category: 'build',
      platform: 'fixture',
      ownership: 'oka',
      prunable: true,
      scope: 'build',
    );
    final repository = CacheWorkspaceRepository(
      environment: {'HOME': p.join(temp.path, 'home')},
      currentDirectory: temp.path,
      sessionStates: _sessionStates(
        SessionStateRegistrySnapshot(
          leases: [
            _lease(
              cacheBuild,
              'state/profile',
              phase: SessionStatePhase.disposing,
              quarantineRelativePath: 'linked/.oka-quarantine-fixture',
            ),
          ],
        ),
      ),
      locations:
          ({
            required projectPath,
            required environment,
            required includeShared,
            required includeProject,
            required liveness,
            toolGuidance = const [],
          }) async => [cacheLocation],
    );

    final workspace = await repository.read(
      CacheWorkspaceRequest(projectPath: project),
    );
    final result = await workspace.inventory.prune(
      scopes: {'build'},
      apply: true,
    );

    expect(workspace.complete, isFalse);
    expect(workspace.warnings, contains(contains('quarantine path')));
    expect(result.selected, isEmpty);
    expect(result.deleted, isEmpty);
    expect(payload.existsSync(), isTrue);
  });

  test(
    'host-scoped opaque Android AVD leases are visible but never prunable',
    () async {
      final avdHome = p.join(temp.path, 'android-avds');
      const avdName = 'Pixel_8_API_35';
      final avdIdentityPath = p.join(avdHome, avdName);
      final avdPayload = File(p.join(avdIdentityPath, 'userdata.img'));
      await avdPayload.parent.create(recursive: true);
      await avdPayload.writeAsString('opaque state');
      final repository = CacheWorkspaceRepository(
        environment: {'HOME': p.join(temp.path, 'home')},
        currentDirectory: temp.path,
        sessionStates: _sessionStates(
          SessionStateRegistrySnapshot(
            leases: [_opaqueAvdLease(avdHome, avdName)],
          ),
        ),
        locations:
            ({
              required projectPath,
              required environment,
              required includeShared,
              required includeProject,
              required liveness,
              toolGuidance = const [],
            }) async => const [],
      );

      final inspection = await CacheTransactions(workspaces: repository)
          .inspect(
            CacheWorkspaceRequest(projectPath: project),
            const CacheInspectRequest(),
          );
      final avdLocation = inspection.storage.locations.single.location;

      expect(avdLocation.category, 'managed-session-state');
      expect(avdLocation.platform, 'android');
      expect(avdLocation.path, avdIdentityPath);
      expect(avdLocation.ownership, 'caller');
      expect(avdLocation.prunable, isFalse);
      expect(avdLocation.inventoryOnly, isTrue);
      expect(inspection.storage.locations.single.sizeBytes, 0);
      expect(inspection.storage.locations.single.complete, isFalse);
      expect(
        inspection.storage.locations.single.warnings,
        contains('Opaque resource size was not measured.'),
      );
      expect(inspection.storage.totalBytes, 0);

      final prune = await inspection.workspace.inventory.prune(
        scopes: {'persistent'},
        apply: true,
      );
      expect(prune.selected, isEmpty);
      expect(prune.deleted, isEmpty);
      expect(avdPayload.existsSync(), isTrue);
    },
  );

  test(
    'session-state registry issues make workspace incomplete and visible',
    () async {
      final repository = CacheWorkspaceRepository(
        environment: {'HOME': p.join(temp.path, 'home')},
        currentDirectory: temp.path,
        sessionStates: _sessionStates(
          const SessionStateRegistrySnapshot(
            issues: [
              SessionStateRegistryIssue(
                path: '/registry/record.json',
                message: 'record is corrupt',
              ),
            ],
          ),
        ),
        locations:
            ({
              required projectPath,
              required environment,
              required includeShared,
              required includeProject,
              required liveness,
              toolGuidance = const [],
            }) async => const [],
      );

      final workspace = await repository.inspect(
        CacheWorkspaceRequest(projectPath: project),
      );

      expect(workspace.complete, isFalse);
      expect(workspace.warnings, contains(contains('record is corrupt')));
      expect(workspace.toJson()['complete'], isFalse);
    },
  );

  test(
    'corrupt session-state registry disables prune and overlapping apply paths',
    () async {
      final cacheBuild = p.join(project, '.oka_cache', 'build');
      final resource = p.join(cacheBuild, 'session-profile');
      await Directory(resource).create(recursive: true);
      final output = File(p.join(cacheBuild, 'app'));
      await output.writeAsString('build output');
      final cacheLocation = StorageLocation(
        id: 'project-build',
        path: cacheBuild,
        category: 'build',
        platform: 'fixture',
        ownership: 'oka',
        prunable: true,
        scope: 'build',
      );
      final repository = CacheWorkspaceRepository(
        environment: {'HOME': p.join(temp.path, 'home')},
        currentDirectory: temp.path,
        sessionStates: _sessionStates(
          SessionStateRegistrySnapshot(
            leases: [_lease(cacheBuild, 'session-profile')],
            issues: [
              const SessionStateRegistryIssue(
                path: '/registry/record.json',
                message: 'record is corrupt',
              ),
            ],
          ),
        ),
        locations:
            ({
              required projectPath,
              required environment,
              required includeShared,
              required includeProject,
              required liveness,
              toolGuidance = const [],
            }) async => [cacheLocation],
      );

      final workspace = await repository.read(
        CacheWorkspaceRequest(projectPath: project),
      );
      final pruned = await workspace.inventory.prune(
        scopes: {'build'},
        apply: true,
      );
      final plan = StorageCleanupPlan(
        selected: [
          StorageMeasurement(
            location: cacheLocation,
            sizeBytes: 12,
            fileCount: 1,
            modifiedAt: DateTime.now(),
            complete: true,
            warnings: const [],
          ),
        ],
      );
      final applied = await workspace.inventory.applyPlan(plan);
      final transactionApplied = await CacheTransactions(
        workspaces: repository,
      ).apply(CacheWorkspaceRequest.saved([project]), plan);

      expect(workspace.complete, isFalse);
      expect(pruned.selected, isEmpty);
      expect(pruned.deleted, isEmpty);
      expect(applied.deleted, isEmpty);
      expect(applied.errors, contains(contains('protected')));
      expect(transactionApplied.deleted, isEmpty);
      expect(transactionApplied.errors, contains(contains('protected')));
      expect(output.existsSync(), isTrue);
      expect(Directory(resource).existsSync(), isTrue);
    },
  );

  test('headless save refuses a plan inside its cleanup selection', () async {
    final workspace = await transactions.workspaces.read(
      CacheWorkspaceRequest(projectPath: project),
    );
    final preview = await transactions.preview(
      workspace,
      const CacheCleanupRequest(scopes: {'build'}),
    );
    final path = p.join(preview.selected.single.location.path, 'plan.json');
    await expectLater(
      transactions.savePlan(path, workspace, preview),
      throwsFormatException,
    );
    expect(File(path).existsSync(), isFalse);
  });

  test(
    'headless save refuses a symlink path into its cleanup selection',
    () async {
      if (Platform.isWindows) return;
      final workspace = await transactions.workspaces.read(
        CacheWorkspaceRequest(projectPath: project),
      );
      final preview = await transactions.preview(
        workspace,
        const CacheCleanupRequest(scopes: {'build'}),
      );
      final alias = Link(p.join(temp.path, 'plan-alias'));
      await alias.create(preview.selected.single.location.path);
      final path = p.join(alias.path, 'reviewed.json');
      await expectLater(
        transactions.savePlan(path, workspace, preview),
        throwsFormatException,
      );
      expect(File(path).existsSync(), isFalse);
    },
  );

  test(
    'registry and location sources are injected with explicit effects',
    () async {
      final projects = _Projects();
      var locationReads = 0;
      final repository = CacheWorkspaceRepository(
        environment: {'HOME': p.join(temp.path, 'isolated-home')},
        currentDirectory: temp.path,
        projects: projects,
        locations:
            ({
              required projectPath,
              required environment,
              required includeShared,
              required includeProject,
              required liveness,
              toolGuidance = const [],
            }) async {
              locationReads++;
              return const [];
            },
      );

      await repository.inspect();
      expect(projects.inspections, 1);
      expect(projects.discoveries, 0);
      expect(projects.registrations, 0);

      await repository.discoverAndRemember(
        CacheWorkspaceRequest(scanRoots: [temp.path]),
      );
      expect(projects.discoveries, 1);
      expect(locationReads, 2);
    },
  );

  test('plain inspect rejects scan roots; discovery is explicit', () async {
    final projects = _Projects();
    final repository = CacheWorkspaceRepository(
      environment: {'HOME': p.join(temp.path, 'isolated-home')},
      currentDirectory: temp.path,
      projects: projects,
      locations:
          ({
            required projectPath,
            required environment,
            required includeShared,
            required includeProject,
            required liveness,
            toolGuidance = const [],
          }) async => const [],
    );
    final api = CacheTransactions(workspaces: repository);
    final request = CacheWorkspaceRequest(scanRoots: [temp.path]);
    await expectLater(
      api.inspect(request, const CacheInspectRequest()),
      throwsArgumentError,
    );
    expect(projects.discoveries, 0);
    await api.discoverAndInspect(request, const CacheInspectRequest());
    expect(projects.discoveries, 1);
  });
}

CacheSessionStateReader _sessionStates(SessionStateRegistrySnapshot snapshot) =>
    () async => snapshot;

SessionStateLease _lease(
  String root,
  String relative, {
  SessionStatePhase phase = SessionStatePhase.ready,
  String? quarantineRelativePath,
}) {
  final now = DateTime.utc(2026);
  return SessionStateLease(
    id: '00000000000000000000000000000001',
    workflowId: 'fixture',
    workflowVersion: 1,
    logicalResourceKey: 'fixture-resource',
    namespace: SessionStateNamespace.project,
    retention: SessionStateRetention.persistent,
    processScope: LeaseScope.ephemeral,
    ownership: SessionStateOwnership.oka,
    acquisitionMode: SessionStateAcquisitionMode.created,
    phase: phase,
    resourceKind: SessionStateResourceKind.directory,
    rootPath: root,
    relativePath: relative,
    markerNonce: 'marker',
    hostId: 'host',
    bootId: 'boot',
    ownerProject: root,
    ownerPid: 1,
    ownerPidToken: 'pid-token',
    createdAt: now,
    updatedAt: now,
    quarantineRelativePath: quarantineRelativePath,
  );
}

SessionStateLease _opaqueAvdLease(String avdHome, String avdName) {
  final now = DateTime.utc(2026);
  return SessionStateLease(
    id: 'opaque-avd-state',
    workflowId: 'android-avd-inventory',
    workflowVersion: 1,
    logicalResourceKey: 'android-avd:$avdHome:$avdName',
    namespace: SessionStateNamespace.host,
    retention: SessionStateRetention.persistent,
    processScope: LeaseScope.persistent,
    ownership: SessionStateOwnership.caller,
    acquisitionMode: SessionStateAcquisitionMode.borrowed,
    phase: SessionStatePhase.ready,
    resourceKind: SessionStateResourceKind.opaque,
    rootPath: avdHome,
    relativePath: avdName,
    markerNonce: 'marker',
    hostId: 'host',
    bootId: 'boot',
    ownerProject: avdHome,
    ownerPid: 1,
    ownerPidToken: 'pid-token',
    createdAt: now,
    updatedAt: now,
    metadata: {
      'provider': 'android-avd',
      'avd_home': avdHome,
      'avd_name': avdName,
    },
  );
}

final class _Projects implements CacheProjectSource {
  int inspections = 0;
  int discoveries = 0;
  int registrations = 0;

  @override
  Future<ProjectDiscovery> discover(List<String> roots) async {
    discoveries++;
    return ProjectDiscovery(projects: const [], warnings: const []);
  }

  @override
  Future<CacheProjectRegistrySnapshot> inspect() async {
    inspections++;
    return const CacheProjectRegistrySnapshot(schemaStatus: 'missing');
  }

  @override
  Future<List<String>> projects() async => const [];

  @override
  Future<void> register(String project) async {
    registrations++;
  }
}
