import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  StorageMeasurement entry(String id, int bytes, DateTime modified) =>
      StorageMeasurement(
        location: StorageLocation(
          id: id,
          path: '/tmp/$id',
          category: 'build-output',
          platform: 'all',
          ownership: 'oka',
          prunable: true,
          scope: 'build',
        ),
        sizeBytes: bytes,
        fileCount: 1,
        modifiedAt: modified,
        complete: true,
        warnings: const [],
      );

  test('selection is pure over the supplied snapshot and time', () {
    final now = DateTime.utc(2026, 9, 22);
    final old = entry('old', 7, now.subtract(const Duration(days: 31)));
    final recent = entry('recent', 11, now.subtract(const Duration(days: 1)));
    final selected = selectStorageCleanup(
      measurements: [recent, old],
      criteria: const StorageSelectionCriteria(olderThan: Duration(days: 30)),
      measuredAt: now,
    );
    expect(selected, [old]);
  });

  test('budget evicts oldest entries deterministically', () {
    final now = DateTime.utc(2026, 9, 22);
    final first = entry('first', 6, now.subtract(const Duration(days: 2)));
    final second = entry('second', 6, now.subtract(const Duration(days: 1)));
    expect(
      selectStorageCleanup(
        measurements: [second, first],
        criteria: const StorageSelectionCriteria(maxTotalBytes: 6),
        measuredAt: now,
      ),
      [first],
    );
  });

  test('injected protected roots participate in deletion safety', () async {
    final temp = await Directory.systemTemp.createTemp('oka-protected-root-');
    addTearDown(() => temp.delete(recursive: true));
    final home = p.join(temp.path, 'injected-home');
    await Directory(home).create();
    final inventory = StorageInventory(
      locations: [
        StorageLocation(
          id: 'unsafe-parent',
          path: temp.path,
          category: 'fixture',
          platform: 'all',
          ownership: 'oka',
          prunable: true,
          scope: 'build',
        ),
      ],
      protectedRoots: [home],
    );
    expect(await inventory.measureEligible(scopes: {'build'}), isEmpty);
  });
}
