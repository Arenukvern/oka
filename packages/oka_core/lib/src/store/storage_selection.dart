import 'storage_inventory.dart';

/// Closed cleanup criteria evaluated against one measured snapshot.
class StorageSelectionCriteria {
  const StorageSelectionCriteria({
    this.scopes = const {'build', 'shared'},
    this.olderThan,
    this.maxTotalBytes,
  });

  final Set<String> scopes;
  final Duration? olderThan;
  final int? maxTotalBytes;

  void validate() {
    if (olderThan?.isNegative ?? false) {
      throw ArgumentError.value(olderThan, 'olderThan');
    }
    if (maxTotalBytes != null && maxTotalBytes! < 0) {
      throw ArgumentError.value(maxTotalBytes, 'maxTotalBytes');
    }
  }
}

/// Selects cleanup entries without filesystem or clock access.
///
/// [measuredAt] makes age decisions reproducible. Callers are responsible for
/// supplying only currently eligible, complete measurements.
List<StorageMeasurement> selectStorageCleanup({
  required Iterable<StorageMeasurement> measurements,
  required StorageSelectionCriteria criteria,
  required DateTime measuredAt,
}) {
  criteria.validate();
  final pool =
      measurements
          .where(
            (entry) =>
                entry.pruneEligible &&
                criteria.scopes.contains(entry.location.scope),
          )
          .toList()
        ..sort((a, b) {
          final age = (a.modifiedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(
                b.modifiedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
              );
          return age == 0 ? a.location.path.compareTo(b.location.path) : age;
        });

  final selected = <StorageMeasurement>[];
  var remaining = pool.fold(0, (sum, entry) => sum + entry.sizeBytes);
  final cutoff = criteria.olderThan == null
      ? null
      : measuredAt.subtract(criteria.olderThan!);
  for (final entry in pool) {
    if ((criteria.olderThan == null && criteria.maxTotalBytes == null) ||
        (cutoff != null &&
            entry.modifiedAt != null &&
            !entry.modifiedAt!.isAfter(cutoff))) {
      selected.add(entry);
      remaining -= entry.sizeBytes;
    }
  }
  if (criteria.maxTotalBytes != null) {
    for (final entry in pool) {
      if (remaining <= criteria.maxTotalBytes!) break;
      if (!selected.contains(entry)) {
        selected.add(entry);
        remaining -= entry.sizeBytes;
      }
    }
  }
  return List.unmodifiable(selected);
}
