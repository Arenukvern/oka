import 'dart:io';

import 'package:path/path.dart' as p;

import 'storage_selection.dart';

export 'storage_selection.dart';

/// A discoverable storage unit. Ownership is descriptive; pruning requires
/// explicit eligibility and a matching scope.
class StorageLocation {
  const StorageLocation({
    required this.id,
    required this.path,
    required this.category,
    required this.platform,
    required this.ownership,
    required this.prunable,
    this.inventoryOnly = false,
    this.scope,
    this.note,
  });
  final String id;
  final String path;
  final String category;
  final String platform;
  final String ownership;
  final bool prunable;

  /// Reports an opaque resource identity without inspecting its filesystem
  /// path or using that path to protect cleanup candidates.
  final bool inventoryOnly;
  final String? scope;
  final String? note;
  Map<String, Object?> toJson() => {
    'id': id,
    'path': path,
    'category': category,
    'platform': platform,
    'ownership': ownership,
    'prunable': prunable,
    'inventory_only': inventoryOnly,
    'scope': scope,
    'note': note,
  };
}

class StorageMeasurement {
  const StorageMeasurement({
    required this.location,
    required this.sizeBytes,
    required this.fileCount,
    required this.modifiedAt,
    required this.complete,
    required this.warnings,
  });
  final StorageLocation location;
  final int sizeBytes;
  final int fileCount;
  final DateTime? modifiedAt;
  final bool complete;
  final List<String> warnings;
  bool get pruneEligible =>
      location.prunable && !location.inventoryOnly && complete;
  Map<String, Object?> toJson() => {
    ...location.toJson(),
    'size_bytes': sizeBytes,
    'file_count': fileCount,
    'modified_at': modifiedAt?.toUtc().toIso8601String(),
    'complete': complete,
    'prune_eligible': pruneEligible,
    'warnings': warnings,
  };
}

class StorageReport {
  const StorageReport({required this.locations, required this.totalBytes});
  final List<StorageMeasurement> locations;

  /// Logical file bytes, deduplicated by absolute path across locations.
  final int totalBytes;
  Map<String, Object?> toJson() => {
    'total_bytes': totalBytes,
    'byte_accounting': 'logical',
    'locations': locations.map((e) => e.toJson()).toList(),
  };
}

/// A reviewed selection, never a source of deletion authority. Applying it
/// requires matching the selection against a newly discovered inventory.
class StorageCleanupPlan {
  StorageCleanupPlan({required List<StorageMeasurement> selected})
    : selected = List.unmodifiable(selected);

  factory StorageCleanupPlan.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != schema || json['selected'] is! List) {
      throw const FormatException('Invalid cache cleanup plan schema');
    }
    final selected = <StorageMeasurement>[];
    for (final raw in json['selected'] as List) {
      if (raw is! Map ||
          raw['id'] is! String ||
          (raw['id'] as String).trim().isEmpty ||
          raw['path'] is! String ||
          !p.isAbsolute(raw['path'] as String) ||
          raw['size_bytes'] is! int ||
          (raw['size_bytes'] as int) < 0 ||
          raw['file_count'] is! int ||
          (raw['file_count'] as int) < 0 ||
          raw['modified_at'] is! String) {
        throw const FormatException('Invalid cache cleanup plan selection');
      }
      final modified = DateTime.tryParse(raw['modified_at'] as String);
      if (modified == null || !modified.isUtc) {
        throw const FormatException('Plan modification time must be UTC');
      }
      selected.add(
        StorageMeasurement(
          location: StorageLocation(
            id: raw['id'] as String,
            path: raw['path'] as String,
            category: 'unverified',
            platform: 'unverified',
            ownership: 'unverified',
            prunable: false,
          ),
          sizeBytes: raw['size_bytes'] as int,
          fileCount: raw['file_count'] as int,
          modifiedAt: modified,
          complete: false,
          warnings: const [],
        ),
      );
    }
    return StorageCleanupPlan(selected: selected);
  }

  static const schema = 'oka.cache.cleanup-plan.v1';
  final List<StorageMeasurement> selected;

  Map<String, Object?> toJson() => {
    'schema': schema,
    'selected': selected.map((entry) => entry.toJson()).toList(),
  };
}

class StoragePruneResult {
  const StoragePruneResult({
    required this.selected,
    required this.deleted,
    required this.errors,
    required this.apply,
  });
  final List<StorageMeasurement> selected;
  final List<StorageMeasurement> deleted;
  final List<String> errors;
  final bool apply;
  int get selectedBytes => selected.fold(0, (sum, e) => sum + e.sizeBytes);
  int get freedBytes => deleted.fold(0, (sum, e) => sum + e.sizeBytes);
  Map<String, Object?> toJson() => {
    'apply': apply,
    'selected_bytes': selectedBytes,
    'freed_bytes': freedBytes,
    'selected': selected.map((e) => e.toJson()).toList(),
    'deleted': deleted.map((e) => e.toJson()).toList(),
    'errors': errors,
  };
}

String _absolute(String path) => p.normalize(p.absolute(path));
bool _contains(String parent, String child) =>
    parent == child || p.isWithin(parent, child);

class StorageInventory {
  StorageInventory({
    required List<StorageLocation> locations,
    Iterable<String> protectedRoots = const [],
    Iterable<String> protectedPaths = const [],
  }) : locations = List.unmodifiable(locations),
       protectedRoots = List.unmodifiable({
         ..._hostProtectedRoots(),
         ...protectedRoots
             .where((root) => root.trim().isNotEmpty)
             .map(_absolute),
       }),
       protectedPaths = List.unmodifiable({
         ...protectedPaths
             .where((path) => path.trim().isNotEmpty)
             .map(_absolute),
       });
  final List<StorageLocation> locations;

  /// Host and injected home roots that a cleanup location must never contain.
  final List<String> protectedRoots;

  /// Registered resources that cleanup locations must not overlap.
  final List<String> protectedPaths;

  /// Scan without traversing symbolic links, including links in ancestors.
  Future<StorageReport> scan() async {
    final files = <String, int>{};
    final measurements = <StorageMeasurement>[];
    for (final location in locations) {
      final measurement = await _measure(location, files);
      if (measurement != null) measurements.add(measurement);
    }
    return StorageReport(
      locations: measurements,
      totalBytes: files.values.fold(0, (a, b) => a + b),
    );
  }

  /// Measures only cleanup candidates while retaining all locations for
  /// protection checks. This avoids traversing large informational SDK data.
  Future<List<StorageMeasurement>> measureEligible({
    Set<String> scopes = const {'build', 'shared'},
  }) async {
    final candidates = <StorageMeasurement>[];
    for (final location in locations) {
      if (!location.prunable ||
          location.inventoryOnly ||
          !scopes.contains(location.scope) ||
          !_safe(location)) {
        continue;
      }
      final measurement = await _measure(location, {});
      if (measurement != null && measurement.complete) {
        candidates.add(measurement);
      }
    }
    candidates.sort(
      (a, b) => _absolute(
        a.location.path,
      ).length.compareTo(_absolute(b.location.path).length),
    );
    final pool = <StorageMeasurement>[];
    for (final candidate in candidates) {
      if (!pool.any(
        (entry) => _contains(
          _absolute(entry.location.path),
          _absolute(candidate.location.path),
        ),
      )) {
        pool.add(candidate);
      }
    }
    return List.unmodifiable(pool);
  }

  Future<bool> _linkedAncestor(String path) async {
    var current = _absolute(path);
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

  Future<StorageMeasurement?> _measure(
    StorageLocation location,
    Map<String, int> files,
  ) async {
    if (location.inventoryOnly) {
      return StorageMeasurement(
        location: location,
        sizeBytes: 0,
        fileCount: 0,
        modifiedAt: null,
        complete: false,
        warnings: const ['Opaque resource size was not measured.'],
      );
    }
    var bytes = 0;
    var count = 0;
    DateTime? modified;
    final warnings = <String>[];
    final root = _absolute(location.path);
    Future<void> visit(String path) async {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        warnings.add('Symbolic link excluded: $path');
        return;
      }
      if (type == FileSystemEntityType.notFound) {
        warnings.add('Path disappeared during scan: $path');
        return;
      }
      final stat = await FileStat.stat(path);
      if (modified == null || stat.modified.isAfter(modified!)) {
        modified = stat.modified;
      }
      if (type == FileSystemEntityType.file) {
        bytes += stat.size;
        count++;
        files[path] = stat.size;
      } else if (type == FileSystemEntityType.directory) {
        await for (final entry in Directory(path).list(followLinks: false)) {
          await visit(entry.path);
        }
      } else {
        warnings.add('Unsupported filesystem entry: $path');
      }
    }

    try {
      if (await _linkedAncestor(root)) {
        warnings.add('Symbolic link in location path: $root');
      } else if (await FileSystemEntity.type(root, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return null;
      } else {
        await visit(root);
      }
    } on FileSystemException catch (error) {
      warnings.add(error.toString());
    }
    if (location.prunable && !_safe(location)) {
      warnings.add('Protected or unsafe location; pruning is disabled: $root');
    }
    return StorageMeasurement(
      location: location,
      sizeBytes: bytes,
      fileCount: count,
      modifiedAt: modified,
      complete: warnings.isEmpty,
      warnings: warnings,
    );
  }

  bool _safe(StorageLocation location) {
    final path = _absolute(location.path);
    if (location.inventoryOnly ||
        location.path.trim().isEmpty ||
        p.dirname(path) == path ||
        protectedRoots.any((root) => _contains(path, root)) ||
        protectedPaths.any(
          (protected) =>
              _contains(path, protected) || _contains(protected, path),
        )) {
      return false;
    }
    return !locations.any(
      (other) =>
          !other.prunable &&
          !other.inventoryOnly &&
          (_contains(path, _absolute(other.path)) ||
              _contains(_absolute(other.path), path)),
    );
  }

  /// Apply only saved entries still owned and eligible in this inventory.
  /// Persisted ownership, scope and eligibility fields are never trusted.
  Future<StoragePruneResult> applyPlan(StorageCleanupPlan plan) {
    final selected = <StorageMeasurement>[];
    final errors = <String>[];
    final paths = <String>[];
    for (final saved in plan.selected) {
      final path = _absolute(saved.location.path);
      if (paths.any(
        (other) => _contains(other, path) || _contains(path, other),
      )) {
        errors.add('Duplicate or overlapping plan entry; skipped: $path');
        continue;
      }
      paths.add(path);
      final matches = locations
          .where(
            (current) =>
                current.id == saved.location.id &&
                _absolute(current.path) == path,
          )
          .toList();
      if (matches.length != 1 ||
          !matches.single.prunable ||
          matches.single.inventoryOnly ||
          !_safe(matches.single)) {
        errors.add('Unknown or protected plan entry; skipped: $path');
        continue;
      }
      selected.add(
        StorageMeasurement(
          location: matches.single,
          sizeBytes: saved.sizeBytes,
          fileCount: saved.fileCount,
          modifiedAt: saved.modifiedAt,
          complete: saved.complete,
          warnings: saved.warnings,
        ),
      );
    }
    return _applySelected(selected, errors);
  }

  /// Select age matches first, then oldest remaining units until the eligible
  /// pool meets the budget. Preview is the default; no external tools run.
  Future<StoragePruneResult> prune({
    Set<String> scopes = const {'build', 'shared'},
    Duration? olderThan,
    int? maxTotalBytes,
    bool apply = false,
  }) async {
    final criteria = StorageSelectionCriteria(
      scopes: scopes,
      olderThan: olderThan,
      maxTotalBytes: maxTotalBytes,
    )..validate();
    // Informational SDKs and emulator disks may be enormous. Pruning needs
    // only scoped candidates; _safe still consults every protected location.
    final pool = await measureEligible(scopes: scopes);
    final selected = selectStorageCleanup(
      measurements: pool,
      criteria: criteria,
      measuredAt: DateTime.now(),
    );
    if (apply) return _applySelected(selected, []);
    return StoragePruneResult(
      selected: selected,
      deleted: const [],
      errors: const [],
      apply: false,
    );
  }

  Future<StoragePruneResult> _applySelected(
    List<StorageMeasurement> selected,
    List<String> errors,
  ) async {
    final deleted = <StorageMeasurement>[];
    for (final item in selected) {
      try {
        final fresh = await _measure(item.location, {});
        if (fresh == null) {
          errors.add('Storage disappeared; skipped: ${item.location.path}');
          continue;
        }
        if (!item.location.prunable ||
            item.location.inventoryOnly ||
            !_safe(item.location) ||
            !fresh.complete ||
            fresh.sizeBytes != item.sizeBytes ||
            fresh.fileCount != item.fileCount ||
            fresh.modifiedAt == null ||
            item.modifiedAt == null ||
            !fresh.modifiedAt!.isAtSameMomentAs(item.modifiedAt!)) {
          errors.add(
            'Storage changed or unsafe; skipped: ${item.location.path}',
          );
          continue;
        }
        final path = _absolute(item.location.path);
        if (await _linkedAncestor(path)) {
          errors.add('Symbolic link detected; skipped: $path');
          continue;
        }
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          await Directory(path).delete(recursive: true);
        } else if (type == FileSystemEntityType.file) {
          await File(path).delete();
        } else {
          errors.add('Storage disappeared or changed type: $path');
          continue;
        }
        deleted.add(fresh);
      } on FileSystemException catch (error) {
        errors.add(error.toString());
      }
    }
    return StoragePruneResult(
      selected: selected,
      deleted: deleted,
      errors: errors,
      apply: true,
    );
  }
}

Iterable<String> _hostProtectedRoots() sync* {
  for (final key in const ['HOME', 'USERPROFILE']) {
    final root = Platform.environment[key];
    if (root != null && root.trim().isNotEmpty) yield _absolute(root);
  }
}
