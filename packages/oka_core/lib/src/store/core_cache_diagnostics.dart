import 'dart:io';

import 'package:path/path.dart' as p;

import '../process_lease_registry.dart';
import 'cache_diagnostics.dart';
import 'cache_projects.dart';

/// First-party, read-only diagnostics for project and process metadata owned
/// by oka_core. Platform packages add richer records through their own
/// providers.
final class CoreCacheDiagnosticProvider implements CacheDiagnosticProvider {
  const CoreCacheDiagnosticProvider();

  @override
  String get id => 'core';

  @override
  Future<CacheDiagnosticContribution> inspect(
    CacheDiagnosticContext context,
  ) async {
    final records = <CacheDiagnosticRecord>[];
    final issues = <CacheDiagnosticIssue>[];
    try {
      final projectRegistry = CacheProjectRegistry(
        environment: context.environment,
      );
      final snapshot = await projectRegistry.inspect();
      final registryId = CacheDiagnosticIds.resource(
        'registry',
        projectRegistry.path,
      );
      records.add(
        CacheDiagnosticRecord(
          id: registryId,
          kind: 'registry',
          label: 'cache projects',
          platform: Platform.operatingSystem,
          path: projectRegistry.path,
          storagePaths: [projectRegistry.path],
          metadata: {
            'schema_status': snapshot.schemaStatus,
            'recorded_project_count': snapshot.projects.length,
            'recorded_projects': [
              for (final path in snapshot.projects)
                {
                  'path': path,
                  'cache_exists':
                      FileSystemEntity.typeSync(
                        p.join(path, '.oka_cache'),
                        followLinks: false,
                      ) ==
                      FileSystemEntityType.directory,
                },
            ],
          },
          observations: [
            _observation(
              context,
              CacheObservationSource.recorded,
              snapshot.schemaStatus,
            ),
          ],
        ),
      );
      for (final issue in snapshot.issues) {
        issues.add(
          CacheDiagnosticIssue(
            providerId: id,
            code: 'project_${issue.code}',
            message: issue.message,
            path: issue.path,
          ),
        );
      }
    } on Object catch (error) {
      issues.add(
        CacheDiagnosticIssue(
          providerId: id,
          code: 'project_registry_unavailable',
          message: error.toString(),
        ),
      );
    }
    for (final project in context.projects) {
      final normalized = p.normalize(p.absolute(project));
      final cachePath = p.join(normalized, '.oka_cache');
      final registryPath = p.join(cachePath, 'processes');
      final projectId = CacheDiagnosticIds.resource('project', normalized);
      records.add(
        CacheDiagnosticRecord(
          id: projectId,
          kind: 'project',
          label: p.basename(normalized),
          platform: Platform.operatingSystem,
          projectPath: normalized,
          path: normalized,
          storagePaths: [cachePath],
          metadata: {
            'cache_exists':
                FileSystemEntity.typeSync(cachePath, followLinks: false) ==
                FileSystemEntityType.directory,
          },
          observations: [
            _observation(
              context,
              CacheObservationSource.filesystem,
              FileSystemEntity.typeSync(
                cachePath,
                followLinks: false,
              ).toString(),
            ),
          ],
        ),
      );
      final registryId = CacheDiagnosticIds.resource('registry', registryPath);
      final registry = ProcessLeaseRegistry(
        Directory(registryPath),
        liveness: context.liveness,
      );
      final snapshot = await registry.inspect();
      records.add(
        CacheDiagnosticRecord(
          id: registryId,
          kind: 'registry',
          label: 'process leases',
          platform: Platform.operatingSystem,
          projectPath: normalized,
          path: registryPath,
          storagePaths: [registryPath],
          relatedIds: [projectId],
          metadata: {
            'schema': 'oka.process-leases.v1',
            'lease_count': snapshot.leases.length,
          },
          observations: [
            _observation(
              context,
              CacheObservationSource.recorded,
              !snapshot.complete
                  ? 'partial'
                  : !registry.directory.existsSync()
                  ? 'missing'
                  : 'valid',
            ),
          ],
        ),
      );
      for (final issue in snapshot.issues) {
        issues.add(
          CacheDiagnosticIssue(
            providerId: id,
            code: 'lease_${_issueCode(issue.message)}',
            message: issue.message,
            path: issue.path,
          ),
        );
      }
      for (final lease in snapshot.leases) {
        final verdict = await registry.checkLiveness(lease);
        final sessionId = CacheDiagnosticIds.session(normalized, lease.id);
        final observations = <CacheDiagnosticObservation>[
          _observation(context, CacheObservationSource.recorded, 'valid'),
          _observation(context, CacheObservationSource.process, verdict.name),
        ];
        records.add(
          CacheDiagnosticRecord(
            id: sessionId,
            kind: 'session',
            label: lease.id,
            platform: Platform.operatingSystem,
            projectPath: normalized,
            path: p.join(registryPath, '${lease.id}.json'),
            storagePaths: [p.join(registryPath, '${lease.id}.json')],
            relatedIds: [projectId, registryId],
            metadata: {
              'lease_kind': lease.kind,
              'pid': lease.pid,
              'scope': lease.scope.label,
              'ownership': lease.ownership.label,
              'owner_command_available': lease.ownerCmd.isNotEmpty,
              'identity': {
                for (final key in const [
                  'avd',
                  'serial',
                  'cdp_port',
                  'session_name',
                  'profile_dir',
                ])
                  if (lease.identity.containsKey(key)) key: lease.identity[key],
              },
              'started_at': lease.startedAt.toIso8601String(),
              'liveness': verdict.name,
            },
            observations: observations,
            actions: [
              CacheDiagnosticAction(
                id: 'inspect-process',
                label: 'Inspect process',
                argv: const ['oka', 'processes', 'list', '--json'],
                cwd: normalized,
              ),
            ],
          ),
        );
      }
    }
    return CacheDiagnosticContribution(records: records, issues: issues);
  }

  CacheDiagnosticObservation _observation(
    CacheDiagnosticContext context,
    CacheObservationSource source,
    String status,
  ) => CacheDiagnosticObservation(
    source: source,
    status: status,
    observedAt: context.observedAt,
  );

  String _issueCode(String message) => message.toLowerCase().contains('json')
      ? 'invalid_json'
      : 'invalid_record';
}
