import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(
    () async => root = Directory(
      await (await Directory.systemTemp.createTemp(
        'oka-inventory-',
      )).resolveSymbolicLinks(),
    ),
  );
  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });
  StorageLocation location(
    String name, {
    bool prunable = true,
    String scope = 'shared',
  }) => StorageLocation(
    id: name,
    path: p.join(root.path, name),
    category: 'cache',
    platform: 'all',
    ownership: 'oka',
    prunable: prunable,
    scope: scope,
  );
  Future<void> file(String path, int bytes) async {
    final target = File(p.join(root.path, path));
    await target.parent.create(recursive: true);
    await target.writeAsBytes(List.filled(bytes, 1));
  }

  test('protects both host and explicitly injected home roots', () {
    final injectedHome = p.join(root.path, 'injected-home');
    final inventory = StorageInventory(
      locations: const [],
      protectedRoots: [injectedHome],
    );

    expect(inventory.protectedRoots, contains(p.normalize(injectedHome)));
    for (final key in const ['HOME', 'USERPROFILE']) {
      final hostHome = Platform.environment[key];
      if (hostHome != null && hostHome.trim().isNotEmpty) {
        expect(
          inventory.protectedRoots,
          contains(p.normalize(p.absolute(hostHome))),
        );
      }
    }
  });

  test(
    'reports missing locations benignly and deduplicates overlaps',
    () async {
      await file('cache/nested/data', 25);
      final report = await StorageInventory(
        locations: [
          location('cache'),
          location('cache/nested'),
          location('absent'),
        ],
      ).scan();
      expect(report.locations, hasLength(2));
      expect(report.totalBytes, 25);
      expect(report.locations.first.fileCount, 1);
      expect(report.toJson()['byte_accounting'], 'logical');
    },
  );
  test(
    'preview preserves files and apply counts only unique deletions',
    () async {
      await file('cache/nested/data', 25);
      final inventory = StorageInventory(
        locations: [location('cache'), location('cache/nested')],
      );
      final preview = await inventory.prune();
      expect(preview.selectedBytes, 25);
      expect(preview.freedBytes, 0);
      expect(Directory(p.join(root.path, 'cache')).existsSync(), isTrue);
      final result = await inventory.prune(apply: true);
      expect(result.freedBytes, 25);
      expect(result.errors, isEmpty);
      expect(Directory(p.join(root.path, 'cache')).existsSync(), isFalse);
    },
  );
  test('protects nonprunable descendants and scopes', () async {
    await file('cache/profile/data', 5);
    await file('tools/data', 10);
    final result = await StorageInventory(
      locations: [
        location('cache'),
        location('cache/profile', prunable: false),
        location('tools', scope: 'tools'),
      ],
    ).prune(apply: true);
    expect(result.selected, isEmpty);
    expect(File(p.join(root.path, 'cache/profile/data')).existsSync(), isTrue);
  });
  test('does not traverse links or prune incomplete locations', () async {
    await file('outside/data', 100);
    await Directory(p.join(root.path, 'cache')).create();
    await Link(
      p.join(root.path, 'cache/link'),
    ).create(p.join(root.path, 'outside'));
    final inventory = StorageInventory(
      locations: [location('cache'), location('cache/link/data')],
    );
    final report = await inventory.scan();
    expect(report.totalBytes, 0);
    expect(report.locations.every((e) => !e.complete), isTrue);
    expect((await inventory.prune(apply: true)).selected, isEmpty);
    expect(File(p.join(root.path, 'outside/data')).existsSync(), isTrue);
  });
  test(
    'budget selects oldest units and zero selects all nonempty units',
    () async {
      await file('older/data', 10);
      await file('newer/data', 20);
      // Explicit ages: filesystems with coarse mtime granularity give both
      // files identical timestamps, and the selector's path tie-break would
      // then order 'newer' before 'older' alphabetically.
      await File(
        p.join(root.path, 'older/data'),
      ).setLastModified(DateTime.now().subtract(const Duration(minutes: 5)));
      final inventory = StorageInventory(
        locations: [location('older'), location('newer')],
      );
      final result = await inventory.prune(maxTotalBytes: 20);
      expect(result.selected, hasLength(1));
      expect(result.selected.first.location.id, 'older');
      expect((await inventory.prune(maxTotalBytes: 0)).selectedBytes, 30);
      expect(
        (await inventory.prune(olderThan: const Duration(days: 1))).selected,
        isEmpty,
      );
    },
  );
  test(
    'age selection precedes budget and uses descendant modification',
    () async {
      await file('old', 10);
      await file('recent', 20);
      await File(
        p.join(root.path, 'old'),
      ).setLastModified(DateTime.now().subtract(const Duration(days: 3)));
      final inventory = StorageInventory(
        locations: [location('old'), location('recent')],
      );
      final ageOnly = await inventory.prune(olderThan: const Duration(days: 1));
      expect(ageOnly.selected.map((e) => e.location.id), ['old']);
      final withBudget = await inventory.prune(
        olderThan: const Duration(days: 1),
        maxTotalBytes: 0,
      );
      expect(withBudget.selectedBytes, 30);
    },
  );
  test('protected ancestors block child pruning', () async {
    await file('external/cache/data', 12);
    final inventory = StorageInventory(
      locations: [
        location('external', prunable: false),
        location('external/cache'),
      ],
    );
    expect((await inventory.prune(apply: true)).selected, isEmpty);
    final report = await inventory.scan();
    expect(report.locations.last.warnings, isNotEmpty);
    expect(File(p.join(root.path, 'external/cache/data')).existsSync(), isTrue);
  });
  test('rejects negative selection constraints', () async {
    final inventory = StorageInventory(locations: []);
    await expectLater(inventory.prune(maxTotalBytes: -1), throwsArgumentError);
    await expectLater(
      inventory.prune(olderThan: const Duration(seconds: -1)),
      throwsArgumentError,
    );
  });

  test(
    'saved plan applies exact selection without adding new candidates',
    () async {
      await file('reviewed/data', 12);
      final original = StorageInventory(locations: [location('reviewed')]);
      final json = StorageCleanupPlan(
        selected: (await original.prune()).selected,
      ).toJson();
      json['discovery'] = {'projects': <String>[]};
      final plan = StorageCleanupPlan.fromJson(json);
      await file('new/data', 25);
      final result = await StorageInventory(
        locations: [location('reviewed'), location('new')],
      ).applyPlan(plan);
      expect(result.freedBytes, 12);
      expect(result.errors, isEmpty);
      expect(File(p.join(root.path, 'new/data')).existsSync(), isTrue);
    },
  );

  test('saved plan rejects changed and added files', () async {
    await file('changed/data', 12);
    await file('added/data', 12);
    final inventory = StorageInventory(
      locations: [location('changed'), location('added')],
    );
    final plan = StorageCleanupPlan(
      selected: (await inventory.prune()).selected,
    );
    await file('changed/data', 13);
    await file('added/extra', 0);
    final result = await inventory.applyPlan(plan);
    expect(result.deleted, isEmpty);
    expect(result.errors, hasLength(2));
    expect(File(p.join(root.path, 'changed/data')).existsSync(), isTrue);
    expect(File(p.join(root.path, 'added/extra')).existsSync(), isTrue);
  });

  test(
    'saved plan rejects modification changes with equal file size',
    () async {
      await file('cache/data', 12);
      final inventory = StorageInventory(locations: [location('cache')]);
      final plan = StorageCleanupPlan(
        selected: (await inventory.prune()).selected,
      );
      await File(
        p.join(root.path, 'cache/data'),
      ).setLastModified(DateTime.now().add(const Duration(days: 1)));
      final result = await inventory.applyPlan(plan);
      expect(result.deleted, isEmpty);
      expect(result.errors, hasLength(1));
    },
  );

  test(
    'forged authority and unknown paths cannot authorize deletion',
    () async {
      await file('protected/data', 12);
      await file('unknown/data', 12);
      final preview = await StorageInventory(
        locations: [location('protected'), location('unknown')],
      ).prune();
      final json = StorageCleanupPlan(selected: preview.selected).toJson();
      for (final row in json['selected']! as List) {
        (row as Map)['prunable'] = true;
        row['ownership'] = 'oka';
        row['prune_eligible'] = true;
      }
      final plan = StorageCleanupPlan.fromJson(json);
      final result = await StorageInventory(
        locations: [location('protected', prunable: false)],
      ).applyPlan(plan);
      expect(result.deleted, isEmpty);
      expect(result.errors, hasLength(2));
      expect(File(p.join(root.path, 'protected/data')).existsSync(), isTrue);
      expect(File(p.join(root.path, 'unknown/data')).existsSync(), isTrue);
    },
  );

  test('new profile protection blocks an unchanged saved parent', () async {
    await file('cache/profile/data', 12);
    final plan = StorageCleanupPlan(
      selected: (await StorageInventory(
        locations: [location('cache')],
      ).prune()).selected,
    );
    final result = await StorageInventory(
      locations: [
        location('cache'),
        location('cache/profile', prunable: false),
      ],
    ).applyPlan(plan);
    expect(result.deleted, isEmpty);
    expect(result.errors, hasLength(1));
    expect(File(p.join(root.path, 'cache/profile/data')).existsSync(), isTrue);
  });

  test(
    'saved plan rejects overlapping entries and missing candidates',
    () async {
      await file('cache/child/data', 12);
      await file('missing/data', 8);
      final inventory = StorageInventory(
        locations: [
          location('cache'),
          location('cache/child'),
          location('missing'),
        ],
      );
      final report = await inventory.scan();
      final plan = StorageCleanupPlan(
        selected: [...report.locations, report.locations.first],
      );
      await Directory(p.join(root.path, 'missing')).delete(recursive: true);
      final result = await inventory.applyPlan(plan);
      expect(result.freedBytes, 12);
      expect(result.deleted, hasLength(1));
      expect(result.errors, hasLength(3));
    },
  );

  test('saved plan never follows a replacement symbolic link', () async {
    await file('cache/data', 12);
    await file('outside/data', 12);
    final inventory = StorageInventory(locations: [location('cache')]);
    final plan = StorageCleanupPlan(
      selected: (await inventory.prune()).selected,
    );
    await Directory(p.join(root.path, 'cache')).delete(recursive: true);
    await Link(p.join(root.path, 'cache')).create(p.join(root.path, 'outside'));
    final result = await inventory.applyPlan(plan);
    expect(result.deleted, isEmpty);
    expect(result.errors, hasLength(1));
    expect(File(p.join(root.path, 'outside/data')).existsSync(), isTrue);
  });

  test(
    'saved plan parsing requires version and strict snapshot fields',
    () async {
      await file('cache/data', 12);
      final preview = await StorageInventory(
        locations: [location('cache')],
      ).prune();
      Map<String, Object?> valid() =>
          StorageCleanupPlan(selected: preview.selected).toJson();
      expect(
        () => StorageCleanupPlan.fromJson({...valid(), 'schema': 'future'}),
        throwsFormatException,
      );
      for (final field in [
        'id',
        'path',
        'size_bytes',
        'file_count',
        'modified_at',
      ]) {
        final json = valid();
        ((json['selected']! as List).first as Map).remove(field);
        expect(
          () => StorageCleanupPlan.fromJson(json),
          throwsFormatException,
          reason: field,
        );
      }
      final relative = valid();
      ((relative['selected']! as List).first as Map)['path'] = 'relative/cache';
      expect(
        () => StorageCleanupPlan.fromJson(relative),
        throwsFormatException,
      );
    },
  );
}
