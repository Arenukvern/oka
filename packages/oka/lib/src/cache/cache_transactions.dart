import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import 'cache_diagnostics_composition.dart';
import 'cache_workspace.dart';

final class CacheInspectRequest {
  const CacheInspectRequest({this.kinds = const {}});
  final Set<String> kinds;
}

final class CacheInspectResult {
  const CacheInspectResult({
    required this.workspace,
    required this.storage,
    required this.diagnostics,
    required this.cleanup,
  });
  final CacheWorkspace workspace;
  final StorageReport storage;
  final CacheDiagnosticReport diagnostics;
  final StoragePruneResult cleanup;
}

final class CacheCleanupRequest {
  const CacheCleanupRequest({
    this.scopes = const {'build', 'shared'},
    this.olderThan,
    this.maxTotalBytes,
  });
  final Set<String> scopes;
  final Duration? olderThan;
  final int? maxTotalBytes;

  StorageSelectionCriteria get criteria => StorageSelectionCriteria(
    scopes: scopes,
    olderThan: olderThan,
    maxTotalBytes: maxTotalBytes,
  );
}

final class CacheCleanupPlanRecord {
  const CacheCleanupPlanRecord({required this.plan, required this.projects});
  final StorageCleanupPlan plan;
  final List<String> projects;
}

abstract interface class CacheCleanupPlanRepository {
  Future<void> save(String path, CacheCleanupPlanRecord record);
  Future<CacheCleanupPlanRecord> read(String path);
}

final class FileCacheCleanupPlanRepository
    implements CacheCleanupPlanRepository {
  const FileCacheCleanupPlanRepository();

  @override
  Future<void> save(String path, CacheCleanupPlanRecord record) async {
    final absolute = p.absolute(path);
    final file = File(absolute);
    await file.parent.create(recursive: true);
    await file.create(exclusive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        ' ',
      ).convert({...record.plan.toJson(), 'projects': record.projects}),
    );
  }

  @override
  Future<CacheCleanupPlanRecord> read(String path) async {
    final decoded = jsonDecode(await File(path).readAsString());
    if (decoded is! Map<String, dynamic> ||
        decoded['projects'] is! List ||
        (decoded['projects'] as List).any(
          (project) =>
              project is! String ||
              project.trim().isEmpty ||
              !p.isAbsolute(project) ||
              p.normalize(project) != project,
        )) {
      throw const FormatException('Invalid cleanup plan project metadata');
    }
    return CacheCleanupPlanRecord(
      plan: StorageCleanupPlan.fromJson(decoded),
      projects: List.unmodifiable((decoded['projects'] as List).cast<String>()),
    );
  }
}

typedef CacheClock = DateTime Function();

/// Headless cache application API used by the CLI and Dart callers.
final class CacheTransactions {
  CacheTransactions({
    required this.workspaces,
    this.plans = const FileCacheCleanupPlanRepository(),
    this.diagnosticProviders,
    Map<String, String>? environment,
    ProcessLiveness? liveness,
    CacheClock? clock,
  }) : environment = environment ?? workspaces.environment,
       liveness = liveness ?? workspaces.liveness,
       _clock = clock ?? DateTime.now;

  final CacheWorkspaceRepository workspaces;
  final CacheCleanupPlanRepository plans;
  final List<CacheDiagnosticProvider>? diagnosticProviders;
  final Map<String, String> environment;
  final ProcessLiveness liveness;
  final CacheClock _clock;

  Future<CacheInspectResult> inspect(
    CacheWorkspaceRequest workspaceRequest,
    CacheInspectRequest request,
  ) async {
    if (workspaceRequest.scanRoots.isNotEmpty) {
      throw ArgumentError.value(
        workspaceRequest.scanRoots,
        'workspaceRequest.scanRoots',
        'Plain inspect is read-only; use discoverAndInspect for scan roots',
      );
    }
    final workspace = await workspaces.inspect(workspaceRequest);
    return inspectWorkspace(workspace, request);
  }

  /// Explicitly discovers and remembers projects, then inspects the resulting
  /// workspace through the same measured transaction as plain [inspect].
  Future<CacheInspectResult> discoverAndInspect(
    CacheWorkspaceRequest workspaceRequest,
    CacheInspectRequest request,
  ) async {
    if (workspaceRequest.scanRoots.isEmpty) {
      throw ArgumentError.value(
        workspaceRequest.scanRoots,
        'workspaceRequest.scanRoots',
        'Discovery requires at least one scan root',
      );
    }
    final workspace = await workspaces.discoverAndRemember(workspaceRequest);
    return inspectWorkspace(workspace, request);
  }

  /// Inspects an already resolved workspace, including caller-composed storage
  /// sources or explicit discovery results, using one measurement snapshot.
  Future<CacheInspectResult> inspectWorkspace(
    CacheWorkspace workspace,
    CacheInspectRequest request,
  ) async {
    final observedAt = _clock().toUtc();
    final report = await workspace.inventory.scan();
    final eligible = report.locations.where((entry) => entry.pruneEligible);
    final selected = selectStorageCleanup(
      measurements: eligible,
      criteria: const StorageSelectionCriteria(),
      measuredAt: observedAt,
    );
    final diagnostics =
        (await CacheDiagnostics(
              providers:
                  diagnosticProviders ?? defaultCacheDiagnosticProviders(),
            ).inspect(
              CacheDiagnosticContext(
                projects: workspace.projects,
                environment: environment,
                storage: report,
                observedAt: observedAt,
                liveness: liveness,
              ),
            ))
            .selectKinds(request.kinds);
    return CacheInspectResult(
      workspace: workspace,
      storage: report,
      diagnostics: diagnostics,
      cleanup: StoragePruneResult(
        selected: selected,
        deleted: const [],
        errors: const [],
        apply: false,
      ),
    );
  }

  Future<StoragePruneResult> preview(
    CacheWorkspace workspace,
    CacheCleanupRequest request,
  ) async {
    final measured = await workspace.inventory.measureEligible(
      scopes: request.scopes,
    );
    return StoragePruneResult(
      selected: selectStorageCleanup(
        measurements: measured,
        criteria: request.criteria,
        measuredAt: _clock(),
      ),
      deleted: const [],
      errors: const [],
      apply: false,
    );
  }

  Future<void> savePlan(
    String path,
    CacheWorkspace workspace,
    StoragePruneResult preview,
  ) async {
    final absolute = p.absolute(path);
    await _rejectLinkedPath(absolute);
    if (preview.selected.any(
      (entry) =>
          p.equals(p.absolute(entry.location.path), absolute) ||
          p.isWithin(p.absolute(entry.location.path), absolute),
    )) {
      throw const FormatException(
        'Save the plan outside the selected cache directories',
      );
    }
    await plans.save(
      path,
      CacheCleanupPlanRecord(
        plan: StorageCleanupPlan(selected: preview.selected),
        projects: workspace.projects,
      ),
    );
  }

  Future<void> _rejectLinkedPath(String path) async {
    var current = p.normalize(path);
    while (true) {
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException(
          'Save the plan through a path without symbolic links',
        );
      }
      final parent = p.dirname(current);
      if (parent == current) return;
      current = parent;
    }
  }

  Future<StoragePruneResult> apply(
    CacheWorkspaceRequest request,
    StorageCleanupPlan reviewed,
  ) async {
    final fresh = await workspaces.read(request);
    return fresh.inventory.applyPlan(reviewed);
  }

  Future<StoragePruneResult> applySavedPlan(String path) async {
    final record = await plans.read(path);
    final fresh = await workspaces.read(
      CacheWorkspaceRequest.saved(record.projects),
    );
    return fresh.inventory.applyPlan(record.plan);
  }
}
