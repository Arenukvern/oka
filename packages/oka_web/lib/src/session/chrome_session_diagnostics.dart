import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// Read-only diagnostics for Oka-managed Chrome profiles and their sessions.
final class BrowserCacheDiagnosticProvider implements CacheDiagnosticProvider {
  const BrowserCacheDiagnosticProvider();

  @override
  String get id => 'web';

  @override
  Future<CacheDiagnosticContribution> inspect(
    final CacheDiagnosticContext context,
  ) async {
    final records = <CacheDiagnosticRecord>[];
    final issues = <CacheDiagnosticIssue>[];
    final measurements = <String, StorageMeasurement>{
      for (final measurement in context.storage.locations)
        measurement.location.path: measurement,
    };
    final profilePaths = <String, _ProfileInfo>{};
    final excludedPaths = <String>{};

    for (final measurement in context.storage.locations.where(
      (final value) => value.location.category == 'browser-profiles',
    )) {
      if (await _hasSymlinkAncestor(measurement.location.path)) {
        excludedPaths.add(measurement.location.path);
        issues.add(
          CacheDiagnosticIssue(
            providerId: id,
            code: 'profile_symlink_excluded',
            message:
                'Profile path is a symbolic link; target was not inspected.',
            path: measurement.location.path,
          ),
        );
        profilePaths[measurement.location.path] ??= _ProfileInfo(
          path: measurement.location.path,
        );
        continue;
      }
      try {
        final type = await FileSystemEntity.type(
          measurement.location.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          await for (final child in Directory(
            measurement.location.path,
          ).list(followLinks: false)) {
            if (child is Directory || child is Link) {
              profilePaths[child.path] ??= _ProfileInfo(path: child.path);
            }
          }
        } else {
          profilePaths[measurement.location.path] ??= _ProfileInfo(
            path: measurement.location.path,
          );
        }
      } on FileSystemException catch (error) {
        issues.add(
          CacheDiagnosticIssue(
            providerId: id,
            code: 'profile_unreadable',
            message: error.message,
            path: measurement.location.path,
          ),
        );
      }
    }

    for (final project in context.projects) {
      final snapshot = await ProcessLeaseRegistry.forProject(project).inspect();
      for (final issue in snapshot.issues) {
        issues.add(
          CacheDiagnosticIssue(
            providerId: id,
            code: 'lease_record_invalid',
            message: issue.message,
            path: issue.path,
          ),
        );
      }
      for (final lease in snapshot.leases.where(
        (final value) => value.kind == 'chrome-session',
      )) {
        final sessionId = CacheDiagnosticIds.session(project, lease.id);
        final profilePath = lease.identity['profile_dir'];
        if (profilePath == null || profilePath.trim().isEmpty) {
          records.add(
            _record(
              project: project,
              path: null,
              profile: _ProfileInfo(
                path: null,
                sessionIds: {sessionId},
                projects: {project},
              ),
              observedAt: context.observedAt,
              lease: lease,
            ),
          );
          continue;
        }
        if (!p.isAbsolute(profilePath)) {
          issues.add(
            CacheDiagnosticIssue(
              providerId: id,
              code: 'profile_path_invalid',
              message:
                  'Recorded profile_dir must be absolute; path was not resolved.',
              path: profilePath,
            ),
          );
          continue;
        }
        final normalized = p.normalize(p.absolute(profilePath));
        final profile = profilePaths[normalized] ??= _ProfileInfo(
          path: normalized,
        );
        profile.projects.add(project);
        profile.sessionIds.add(sessionId);
        final cdpPort = lease.identity['cdp_port'];
        if (cdpPort != null) profile.cdpPorts.add(cdpPort);
        final sessionName = lease.identity['session_name'];
        if (sessionName != null) profile.sessionNames.add(sessionName);
        profile.persistence ??= lease.scope == LeaseScope.persistent
            ? 'persistent'
            : 'ephemeral';
      }
    }

    for (final profile in profilePaths.values) {
      var excluded =
          profile.path != null && excludedPaths.contains(profile.path);
      if (profile.path != null &&
          !excluded &&
          await _hasSymlinkAncestor(profile.path!)) {
        excludedPaths.add(profile.path!);
        excluded = true;
        issues.add(
          CacheDiagnosticIssue(
            providerId: id,
            code: 'profile_symlink_excluded',
            message:
                'Profile path is a symbolic link; target was not inspected.',
            path: profile.path,
          ),
        );
      }
      var measurement = excluded || profile.path == null
          ? null
          : measurements[profile.path];
      if (!excluded &&
          measurement == null &&
          profile.path != null &&
          await FileSystemEntity.type(profile.path!, followLinks: false) ==
              FileSystemEntityType.directory) {
        measurement = (await StorageInventory(
          locations: [
            StorageLocation(
              id: 'browser:${profile.path}',
              path: profile.path!,
              category: 'browser-profiles',
              platform: 'web',
              ownership: 'user',
              prunable: false,
            ),
          ],
        ).scan()).locations.singleOrNull;
      }
      if (measurement != null && !measurement.complete) {
        for (final warning in measurement.warnings) {
          issues.add(
            CacheDiagnosticIssue(
              providerId: id,
              code: 'profile_measurement_partial',
              message: warning,
              path: profile.path,
            ),
          );
        }
      }
      records.add(
        _record(
          project:
              profile.projects.firstOrNull ??
              _projectFor(profile.path, context.projects),
          path: profile.path,
          profile: profile,
          observedAt: context.observedAt,
          measurement: measurement,
          excluded: excludedPaths.contains(profile.path),
        ),
      );
    }
    return CacheDiagnosticContribution(records: records, issues: issues);
  }

  CacheDiagnosticRecord _record({
    required final String? project,
    required final String? path,
    required final _ProfileInfo profile,
    required final DateTime observedAt,
    ProcessLease? lease,
    StorageMeasurement? measurement,
    bool excluded = false,
  }) {
    final sessionIds = profile.sessionIds.toList()..sort();
    final metadata = <String, Object?>{
      'session_ids': sessionIds,
      'persistence': profile.persistence ?? 'unknown',
      'runtime_status': 'unknown',
      'existence': excluded
          ? 'excluded'
          : path == null
          ? 'unknown'
          : switch (FileSystemEntity.typeSync(path, followLinks: false)) {
              FileSystemEntityType.file => 'file',
              FileSystemEntityType.directory => 'directory',
              FileSystemEntityType.link => 'link',
              FileSystemEntityType.notFound => 'not_found',
              _ => 'unknown',
            },
      'size_bytes': measurement?.sizeBytes,
      'file_count': measurement?.fileCount,
      'storage_complete': measurement?.complete,
      'measurement_excluded': excluded,
      'cdp_ports': profile.cdpPorts.toList()..sort(),
      'session_names': profile.sessionNames.toList()..sort(),
      if (lease != null) ...{
        'session_name': lease.identity['session_name'],
        'cdp_port': lease.identity['cdp_port'],
      },
    };
    return CacheDiagnosticRecord(
      id: path == null
          ? 'browser-profile:unknown:${CacheDiagnosticIds.session(project!, lease!.id)}'
          : CacheDiagnosticIds.resource('browser-profile', path),
      kind: 'browser-profile',
      label: path == null ? 'Unknown Chrome profile' : p.basename(path),
      platform: 'web',
      projectPath: project,
      path: path,
      storagePaths: path == null ? const [] : [path],
      relatedIds: sessionIds,
      metadata: metadata,
      observations: [
        CacheDiagnosticObservation(
          source: path == null
              ? CacheObservationSource.recorded
              : CacheObservationSource.filesystem,
          status: excluded
              ? 'excluded'
              : path == null
              ? 'unknown'
              : 'observed',
          observedAt: observedAt,
        ),
      ],
    );
  }
}

Future<bool> _hasSymlinkAncestor(final String path) async {
  var current = p.normalize(p.absolute(path));
  while (true) {
    if (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.link) {
      return true;
    }
    final parent = p.dirname(current);
    if (parent == current) return false;
    current = parent;
  }
}

String? _projectFor(final String? path, final List<String> projects) {
  if (path == null) return null;
  for (final project in projects) {
    final cache = p.normalize(p.join(project, '.oka_cache'));
    if (path == cache || p.isWithin(cache, path)) return project;
  }
  return null;
}

final class _ProfileInfo {
  _ProfileInfo({
    required this.path,
    Set<String>? sessionIds,
    Set<String>? projects,
  }) : sessionIds = sessionIds ?? <String>{},
       projects = projects ?? <String>{};
  final String? path;
  final Set<String> sessionIds;
  final Set<String> projects;
  final Set<String> cdpPorts = <String>{};
  final Set<String> sessionNames = <String>{};
  String? persistence;
}
