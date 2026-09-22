import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _Liveness implements ProcessLiveness {
  @override
  Future<bool> isAlive(int pid) async => true;

  @override
  Future<String?> identityToken(int pid) async => 'token';

  @override
  Future<bool> kill(
    int pid, {
    Duration grace = const Duration(seconds: 3),
  }) async => false;
}

ProcessLease _lease(String id, {int pid = 0}) => ProcessLease(
  id: id,
  pid: pid,
  kind: 'chrome-session',
  identity: const {'profile': 'temporary'},
  scope: LeaseScope.session,
  ownership: LeaseOwnership.borrowed,
  ownerCmd: 'oka dev',
  startedAt: DateTime.utc(2026, 9, 22),
  stopHint: const LeaseStopHint(tool: 'true'),
);

void main() {
  late Directory root;
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('oka-diagnostics-'),
  );
  tearDown(() => root.delete(recursive: true));

  test(
    'linked registries are excluded and PID-zero reconciliation keeps the record',
    () async {
      final external = File(p.join(root.path, 'outside.json'));
      await external.writeAsString('{"schema_version":1,"projects":[]}');
      final linked = p.join(root.path, 'registry.json');
      await Link(linked).create(external.path);
      final snapshot = await CacheProjectRegistry(path: linked).inspect();
      expect(snapshot.schemaStatus, 'invalid');
      expect(snapshot.issues.single.code, 'excluded_path');
      final registry = ProcessLeaseRegistry.forProject(
        root.path,
        liveness: _Liveness(),
      );
      await registry.upsert(_lease('borrowed'));
      final summary = await reconcileLeases(root.path, liveness: _Liveness());
      expect(summary.unverifiable, ['borrowed']);
      expect(summary.droppedStale, isEmpty);
      expect(await registry.read('borrowed'), isNotNull);
    },
  );

  test(
    'default diagnostics omit raw command and arbitrary identity values',
    () async {
      final registry = ProcessLeaseRegistry.forProject(root.path);
      await registry.upsert(
        _lease('private').copyWith(
          identity: {'secret': 'do-not-print', 'session_name': 'main'},
        ),
      );
      final report =
          await CacheDiagnostics(
            providers: [const CoreCacheDiagnosticProvider()],
          ).inspect(
            CacheDiagnosticContext(
              projects: [root.path],
              environment: {'HOME': root.path},
              storage: const StorageReport(locations: [], totalBytes: 0),
            ),
          );
      final session = report.records.singleWhere((r) => r.kind == 'session');
      expect(session.metadata.containsKey('owner_cmd'), isFalse);
      expect(jsonEncode(session.toJson()), isNot(contains('do-not-print')));
      expect((session.metadata['identity']! as Map)['session_name'], 'main');
    },
  );

  test(
    'lease snapshot preserves valid siblings and malformed issues',
    () async {
      final leases = Directory(p.join(root.path, '.oka_cache', 'processes'))
        ..createSync(recursive: true);
      final registry = ProcessLeaseRegistry(leases, liveness: _Liveness());
      await registry.upsert(_lease('good'));
      File(p.join(leases.path, 'broken.json')).writeAsStringSync('{broken');
      final snapshot = await registry.inspect();
      expect(snapshot.leases.single.id, 'good');
      expect(snapshot.issues, hasLength(1));
      expect(snapshot.complete, isFalse);
    },
  );

  test(
    'provider exposes missing projects and does not create metadata',
    () async {
      final project = p.join(root.path, 'missing-project');
      final before = Directory(
        root.path,
      ).listSync().map((e) => e.path).toList();
      final context = CacheDiagnosticContext(
        projects: [project],
        environment: {'HOME': root.path},
        storage: const StorageReport(locations: [], totalBytes: 0),
        observedAt: DateTime.utc(2026, 9, 22),
        liveness: _Liveness(),
      );
      final contribution = await const CoreCacheDiagnosticProvider().inspect(
        context,
      );
      expect(contribution.issues, isEmpty);
      expect(
        contribution.records.map((r) => r.kind),
        containsAll(<String>['project', 'registry']),
      );
      expect(
        contribution.records
            .singleWhere((r) => r.kind == 'project')
            .projectPath,
        project,
      );
      expect(Directory(p.join(project, '.oka_cache')).existsSync(), isFalse);
      expect(
        Directory(root.path).listSync().map((e) => e.path).toList(),
        before,
      );
    },
  );

  test(
    'project snapshot preserves valid paths beside malformed entries',
    () async {
      final registryPath = p.join(root.path, 'registry.json');
      final valid = p.join(root.path, 'recorded');
      await File(registryPath).writeAsString(
        '{"schema_version":1,"projects":["$valid",42,"relative"]}',
      );
      final snapshot = await CacheProjectRegistry(path: registryPath).inspect();
      expect(snapshot.schemaStatus, 'valid');
      expect(snapshot.projects, [valid]);
      expect(snapshot.issues, hasLength(2));
    },
  );

  test(
    'provider keeps missing global recorded projects with registry issues',
    () async {
      final recorded = p.join(root.path, 'recorded-but-missing');
      final registryPath = p.join(root.path, '.oka', 'cache-projects.json');
      await Directory(p.dirname(registryPath)).create(recursive: true);
      await File(
        registryPath,
      ).writeAsString('{"schema_version":1,"projects":["$recorded",42]}');
      final contribution = await const CoreCacheDiagnosticProvider().inspect(
        CacheDiagnosticContext(
          projects: const [],
          environment: {'HOME': root.path},
          storage: const StorageReport(locations: [], totalBytes: 0),
          liveness: _Liveness(),
        ),
      );
      final registry = contribution.records.singleWhere(
        (record) => record.kind == 'registry',
      );
      expect(registry.metadata['recorded_project_count'], 1);
      expect((registry.metadata['recorded_projects']! as List).single, {
        'path': recorded,
        'cache_exists': false,
      });
      expect(contribution.issues, hasLength(1));
    },
  );

  test(
    'session IDs are project qualified and pid zero remains unknown',
    () async {
      final projectA = p.join(root.path, 'a');
      final projectB = p.join(root.path, 'b');
      for (final project in [projectA, projectB]) {
        final registry = ProcessLeaseRegistry.forProject(
          project,
          liveness: _Liveness(),
        );
        await registry.upsert(_lease('same'));
      }
      final context = CacheDiagnosticContext(
        projects: [projectA, projectB],
        environment: {'HOME': root.path},
        storage: const StorageReport(locations: [], totalBytes: 0),
        liveness: _Liveness(),
      );
      final report = await CacheDiagnostics(
        providers: [const CoreCacheDiagnosticProvider()],
      ).inspect(context);
      final sessions = report.records
          .where((r) => r.kind == 'session')
          .toList();
      expect(sessions.map((r) => r.id).toSet(), {
        CacheDiagnosticIds.session(p.normalize(p.absolute(projectA)), 'same'),
        CacheDiagnosticIds.session(p.normalize(p.absolute(projectB)), 'same'),
      });
      expect(
        sessions.every((r) => r.metadata['liveness'] == 'unknown'),
        isTrue,
      );
    },
  );
}
