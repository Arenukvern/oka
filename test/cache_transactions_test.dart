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

  test('headless save refuses a symlink path into its cleanup selection',
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
  });

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
      locations: ({
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
