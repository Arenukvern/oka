import 'dart:convert';

import '../process_liveness.dart';
import 'storage_inventory.dart';

/// Explicit inputs: inspection never discovers or executes project code.
/// Supply canonical absolute project paths so all providers share relation IDs.
final class CacheDiagnosticContext {
  CacheDiagnosticContext({
    required List<String> projects,
    required Map<String, String> environment,
    required this.storage,
    DateTime? observedAt,
    this.liveness = const HostProcessLiveness(),
  }) : projects = List.unmodifiable(projects),
       environment = Map.unmodifiable(environment),
       observedAt = (observedAt ?? DateTime.now()).toUtc();

  final List<String> projects;
  final Map<String, String> environment;
  final StorageReport storage;
  final DateTime observedAt;
  final ProcessLiveness liveness;
}

/// Open extension point for platform packages; implementations must be read-only.
abstract interface class CacheDiagnosticProvider {
  String get id;
  Future<CacheDiagnosticContribution> inspect(CacheDiagnosticContext context);
}

final class CacheDiagnosticContribution {
  const CacheDiagnosticContribution({
    this.records = const [],
    this.issues = const [],
  });
  final List<CacheDiagnosticRecord> records;
  final List<CacheDiagnosticIssue> issues;
}

enum CacheObservationSource { recorded, filesystem, process }

final class CacheDiagnosticObservation {
  const CacheDiagnosticObservation({
    required this.source,
    required this.status,
    required this.observedAt,
    this.detail,
  });
  final CacheObservationSource source;
  final String status;
  final DateTime observedAt;
  final String? detail;
  Map<String, Object?> toJson() => {
    'source': source.name,
    'status': status,
    'observed_at': observedAt.toUtc().toIso8601String(),
    'detail': detail,
  };
}

/// A suggestion only; callers explicitly choose whether to execute it.
final class CacheDiagnosticAction {
  const CacheDiagnosticAction({
    required this.id,
    required this.label,
    required this.argv,
    required this.cwd,
    this.destructive = false,
  });
  final String id;
  final String label;
  final List<String> argv;
  final String cwd;
  final bool destructive;
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'argv': argv,
    'cwd': cwd,
    'destructive': destructive,
  };
}

/// Common navigable envelope, with provider-owned JSON-compatible metadata.
/// Sizes in metadata are explanatory; they never augment storage totals.
final class CacheDiagnosticRecord {
  const CacheDiagnosticRecord({
    required this.id,
    required this.kind,
    required this.label,
    required this.platform,
    this.projectPath,
    this.path,
    this.storagePaths = const [],
    this.relatedIds = const [],
    this.metadata = const {},
    this.observations = const [],
    this.actions = const [],
  });
  final String id;
  final String kind;
  final String label;
  final String platform;
  final String? projectPath;
  final String? path;
  final List<String> storagePaths;
  final List<String> relatedIds;
  final Map<String, Object?> metadata;
  final List<CacheDiagnosticObservation> observations;
  final List<CacheDiagnosticAction> actions;
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'label': label,
    'platform': platform,
    'project': projectPath,
    'path': path,
    'storage_paths': storagePaths,
    'related_ids': relatedIds,
    'metadata': metadata,
    'observations': observations.map((e) => e.toJson()).toList(),
    'actions': actions.map((e) => e.toJson()).toList(),
  };
}

final class CacheDiagnosticIssue {
  const CacheDiagnosticIssue({
    required this.providerId,
    required this.code,
    required this.message,
    this.path,
  });
  final String providerId;
  final String code;
  final String message;
  final String? path;
  Map<String, Object?> toJson() => {
    'provider': providerId,
    'code': code,
    'message': message,
    'path': path,
  };
}

/// Stable IDs: projects disambiguate otherwise identical lease IDs.
// A shared namespace keeps provider-generated relation IDs consistent.
// ignore: avoid_classes_with_only_static_members
abstract final class CacheDiagnosticIds {
  static String session(String project, String leaseId) =>
      'session:${Uri.encodeComponent(project)}:${Uri.encodeComponent(leaseId)}';
  static String resource(String kind, String path) =>
      '$kind:${Uri.encodeComponent(path)}';
}

final class CacheDiagnosticReport {
  CacheDiagnosticReport({
    required this.observedAt,
    required List<CacheDiagnosticRecord> records,
    required List<CacheDiagnosticIssue> issues,
    required Map<String, String> providers,
  }) : records = List.unmodifiable(records),
       issues = List.unmodifiable(issues),
       providers = Map.unmodifiable(providers);
  static const schema = 'oka.cache.diagnostics.v1';
  final DateTime observedAt;
  final List<CacheDiagnosticRecord> records;
  final List<CacheDiagnosticIssue> issues;

  /// Record ID to contributing provider ID, also the JSON metadata namespace.
  final Map<String, String> providers;
  bool get complete => issues.isEmpty;
  CacheDiagnosticReport selectKinds(Set<String> kinds) => CacheDiagnosticReport(
    observedAt: observedAt,
    records: records
        .where((r) => kinds.isEmpty || kinds.contains(r.kind))
        .toList(),
    issues: issues,
    providers: providers,
  );
  Map<String, Object?> toJson() => {
    'schema_version': schema,
    'observed_at': observedAt.toIso8601String(),
    'complete': complete,
    'records': records
        .map(
          (r) => {
            ...r.toJson(),
            'provider': providers[r.id],
            'metadata': {providers[r.id]!: r.metadata},
          },
        )
        .toList(),
    'issues': issues.map((e) => e.toJson()).toList(),
  };
}

/// Composes independent providers; one broken source cannot hide valid siblings.
final class CacheDiagnostics {
  CacheDiagnostics({required List<CacheDiagnosticProvider> providers})
    : providers = List.unmodifiable(providers);
  final List<CacheDiagnosticProvider> providers;
  Future<CacheDiagnosticReport> inspect(CacheDiagnosticContext context) async {
    final records = <CacheDiagnosticRecord>[];
    final issues = <CacheDiagnosticIssue>[];
    final owners = <String, String>{};
    final seen = <String>{};
    for (final provider in providers) {
      if (provider.id.isEmpty || !seen.add(provider.id)) {
        issues.add(
          CacheDiagnosticIssue(
            providerId: provider.id,
            code: 'duplicate_provider',
            message: 'Provider IDs must be nonempty and unique.',
          ),
        );
        continue;
      }
      try {
        final result = await provider.inspect(context);
        issues.addAll(result.issues);
        for (final record in result.records) {
          if (record.id.isEmpty || owners.containsKey(record.id)) {
            issues.add(
              CacheDiagnosticIssue(
                providerId: provider.id,
                code: 'duplicate_record',
                message:
                    'Record ID is empty or already contributed: ${record.id}',
              ),
            );
            continue;
          }
          try {
            jsonEncode(record.toJson());
          } on Object catch (error) {
            issues.add(
              CacheDiagnosticIssue(
                providerId: provider.id,
                code: 'invalid_metadata',
                message: 'Record ${record.id}: $error',
              ),
            );
            continue;
          }
          owners[record.id] = provider.id;
          records.add(record);
        }
      } on Object catch (error) {
        issues.add(
          CacheDiagnosticIssue(
            providerId: provider.id,
            code: 'provider_failed',
            message: error.toString(),
          ),
        );
      }
    }
    records.sort((a, b) => a.id.compareTo(b.id));
    return CacheDiagnosticReport(
      observedAt: context.observedAt,
      records: records,
      issues: issues,
      providers: owners,
    );
  }
}
