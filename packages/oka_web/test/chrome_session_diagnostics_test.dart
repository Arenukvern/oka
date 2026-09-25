import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_web/oka_web.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(
    () => temp = Directory(
      Directory.systemTemp
          .createTempSync('oka_web_diag_')
          .resolveSymbolicLinksSync(),
    ),
  );
  tearDown(() => temp.deleteSync(recursive: true));

  StorageReport storageFor(Iterable<String> paths) => StorageReport(
    locations: [
      for (final path in paths)
        StorageMeasurement(
          location: StorageLocation(
            id: 'browser:$path',
            path: path,
            category: 'browser-profiles',
            platform: 'web',
            ownership: 'user',
            prunable: false,
          ),
          sizeBytes: 42,
          fileCount: 2,
          modifiedAt: DateTime.utc(2026),
          complete: true,
          warnings: const [],
        ),
    ],
    totalBytes: paths.length * 42,
  );

  Future<void> writeLease(String project, ProcessLease lease) async {
    await ProcessLeaseRegistry.forProject(project).upsert(lease);
  }

  ProcessLease lease({
    required String id,
    required String? profile,
    String session = 'main',
    String port = '9222',
  }) => ProcessLease(
    id: id,
    pid: 0,
    kind: 'chrome-session',
    identity: {
      'profile_dir': ?profile,
      'session_name': session,
      'cdp_port': port,
    },
    scope: LeaseScope.persistent,
    ownership: LeaseOwnership.borrowed,
    ownerCmd: 'oka run chrome-session',
    startedAt: DateTime.utc(2026),
    stopHint: const LeaseStopHint(tool: 'kill'),
  );

  CacheDiagnosticContext context(
    List<String> projects, {
    StorageReport? storage,
  }) => CacheDiagnosticContext(
    projects: projects,
    environment: const {},
    storage: storage ?? storageFor(const []),
    observedAt: DateTime.utc(2026, 1, 2),
  );

  test('reports persistent profile metadata and storage measurement', () async {
    final project = p.join(temp.path, 'project');
    final profile = p.join(project, '.oka_cache', 'chrome-profiles', 'main');
    await Directory(profile).create(recursive: true);
    await writeLease(
      project,
      lease(id: 'chrome-main', profile: profile, session: 'dev', port: '9333'),
    );

    final report = await const BrowserCacheDiagnosticProvider().inspect(
      context([project], storage: storageFor([profile])),
    );
    final record = report.records.single;
    expect(record.projectPath, project);
    expect(record.path, profile);
    expect(record.relatedIds, [
      CacheDiagnosticIds.session(project, 'chrome-main'),
    ]);
    expect(record.metadata['persistence'], 'persistent');
    expect(record.metadata['size_bytes'], 42);
    expect(record.metadata['cdp_ports'], ['9333']);
    expect(record.metadata['session_names'], ['dev']);
  });

  test('reports a managed profile after its process lease is gone', () async {
    final project = p.join(temp.path, 'project');
    final profile = p.join(
      project,
      '.oka_cache',
      'session-state',
      'chrome',
      'main',
    );
    await Directory(p.join(profile, 'Default')).create(recursive: true);
    final storage = StorageReport(
      locations: [
        StorageMeasurement(
          location: StorageLocation(
            id: 'session-state-0123456789abcdef0123456789abcdef',
            path: profile,
            category: 'managed-session-state',
            platform: 'chromium',
            ownership: 'oka',
            prunable: false,
            scope: 'ephemeral',
          ),
          sizeBytes: 64,
          fileCount: 3,
          modifiedAt: DateTime.utc(2026),
          complete: true,
          warnings: const [],
        ),
      ],
      totalBytes: 64,
    );

    final report = await const BrowserCacheDiagnosticProvider().inspect(
      context([project], storage: storage),
    );

    expect(report.records, hasLength(1));
    expect(report.records.single.kind, 'browser-profile');
    expect(report.records.single.path, profile);
    expect(report.records.single.metadata['persistence'], 'ephemeral');
    expect(report.records.single.metadata['state_lease_ids'], [
      '0123456789abcdef0123456789abcdef',
    ]);
  });

  test('reports a recorded temporary profile outside the project', () async {
    final project = p.join(temp.path, 'project');
    final profile = p.join(temp.path, 'oka-chrome-main-temp');
    await Directory(profile).create(recursive: true);
    await writeLease(project, lease(id: 'chrome-main', profile: profile));

    final report = await const BrowserCacheDiagnosticProvider().inspect(
      context([project]),
    );
    expect(report.records.single.path, profile);
    expect(report.records.single.projectPath, project);
    expect(report.records.single.metadata['size_bytes'], 0);
  });

  test('keeps old leases readable with unknown profile metadata', () async {
    final project = p.join(temp.path, 'project');
    await writeLease(project, lease(id: 'chrome-old', profile: null));

    final report = await const BrowserCacheDiagnosticProvider().inspect(
      context([project]),
    );
    expect(report.issues, isEmpty);
    expect(report.records.single.path, isNull);
    expect(report.records.single.metadata['persistence'], 'unknown');
    expect(report.records.single.metadata['cdp_ports'], isEmpty);
  });

  test('scopes related session IDs across projects', () async {
    final projectA = p.join(temp.path, 'a');
    final projectB = p.join(temp.path, 'b');
    final profile = p.join(temp.path, 'shared-profile');
    await Directory(profile).create(recursive: true);
    await writeLease(projectA, lease(id: 'chrome-main', profile: profile));
    await writeLease(projectB, lease(id: 'chrome-main', profile: profile));

    final report = await const BrowserCacheDiagnosticProvider().inspect(
      context([projectA, projectB]),
    );
    expect(
      report.records.single.relatedIds,
      containsAll([
        CacheDiagnosticIds.session(projectA, 'chrome-main'),
        CacheDiagnosticIds.session(projectB, 'chrome-main'),
      ]),
    );
  });

  test('reports malformed leases without hiding valid profiles', () async {
    final project = p.join(temp.path, 'project');
    final profile = p.join(project, '.oka_cache', 'chrome-profiles', 'main');
    await Directory(
      p.join(project, '.oka_cache', 'processes'),
    ).create(recursive: true);
    await File(
      p.join(project, '.oka_cache', 'processes', 'bad.json'),
    ).writeAsString('{bad');
    await writeLease(project, lease(id: 'chrome-main', profile: profile));

    final report = await const BrowserCacheDiagnosticProvider().inspect(
      context([project], storage: storageFor([profile])),
    );
    expect(report.records, hasLength(1));
    expect(
      report.issues.map((issue) => issue.code),
      contains('lease_record_invalid'),
    );
  });

  test('reports symlink ancestors without following them', () async {
    final project = p.join(temp.path, 'project');
    final real = p.join(temp.path, 'real');
    final linked = p.join(temp.path, 'linked');
    await Directory(p.join(real, 'profile')).create(recursive: true);
    Link(linked).createSync(real);
    final profile = p.join(linked, 'profile');
    await writeLease(project, lease(id: 'chrome-linked', profile: profile));

    final report = await const BrowserCacheDiagnosticProvider().inspect(
      context([project]),
    );
    expect(report.issues.single.code, 'profile_symlink_excluded');
    expect(report.records.single.path, profile);
    expect(report.records.single.metadata['existence'], 'excluded');
    expect(report.records.single.metadata['size_bytes'], isNull);
  });
}
