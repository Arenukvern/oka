import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/contracts/duplicate_train_inventory_scan.dart';
import '../tool/release/train_inventory.dart';
import 'support/repo_root.dart';

/// Three train names used in positive escape fixtures.
const _threeTrain = '''
  'oka_process',
  'oka_core',
  'oka_artifacts',
''';

void main() {
  group('content-based duplicate train inventory scan', () {
    final escapeCases = <String, String>{
      'no String type argument': '''
void main() {
  const packages = [
$_threeTrain
  ];
}
''',
      'List<String> typed variable': '''
void main() {
  const List<String> packages = [
$_threeTrain
  ];
}
''',
      'final packages': '''
void main() {
  final packages = <String>[
$_threeTrain
  ];
}
''',
      'renamed const kTrain': '''
void main() {
  const kTrain = <String>[
$_threeTrain
  ];
}
''',
      'declaration split across lines': '''
void main() {
  const packages
      = <
    String
  >[
$_threeTrain
  ];
}
''',
      'inline list in for loop': '''
void main() {
  for (final name in [
$_threeTrain
  ]) {
    print(name);
  }
}
''',
      'set literal': '''
void main() {
  const names = <String>{
$_threeTrain
  };
}
''',
      'map literal keys': '''
void main() {
  const v = <String, String>{
    'oka_process': '1',
    'oka_core': '1',
    'oka_artifacts': '1',
  };
}
''',
      'spread list elements': '''
void main() {
  const all = <String>[
    ...['oka_process'],
    ...['oka_core'],
    ...['oka_artifacts'],
  ];
}
''',
    };

    for (final entry in escapeCases.entries) {
      test('flags escape: ${entry.key}', () {
        final hits = scanDuplicateTrainPackageListsInSource(
          'fixture/escape_${entry.key.hashCode}.dart',
          entry.value,
        );
        expect(
          hits,
          isNotEmpty,
          reason: 'expected violation for ${entry.key}',
        );
      });
    }

    test('negative: only two train package names', () {
      final hits = scanDuplicateTrainPackageListsInSource(
        'fixture/two_names.dart',
        '''
void main() {
  const partial = ['oka_process', 'oka_core'];
}
''',
      );
      expect(hits, isEmpty);
    });

    test('negative: unrelated strings', () {
      final hits = scanDuplicateTrainPackageListsInSource(
        'fixture/unrelated.dart',
        '''
void main() {
  const labels = ['alpha', 'beta', 'gamma', 'delta'];
}
''',
      );
      expect(hits, isEmpty);
    });

    test('mutation: line-based scan misses all escape fixtures (RED)', () {
      final root = Directory.systemTemp.createTempSync('oka-dup-inv-mutation-');
      addTearDown(() => root.deleteSync(recursive: true));
      final fixtureDir = Directory(p.join(root.path, 'fixture'))
        ..createSync();
      var index = 0;
      for (final source in escapeCases.values) {
        File(p.join(fixtureDir.path, 'case_$index.dart'))
            .writeAsStringSync(source);
        index++;
      }
      final legacy = findDuplicateTrainPackageListsLineBased(root);
      expect(
        legacy,
        isEmpty,
        reason: 'legacy line-based scan should miss content-based escapes '
            '(mutation baseline); got: $legacy',
      );
    });

    test('mutation: content-based scan flags every escape fixture (GREEN)', () {
      final root = Directory.systemTemp.createTempSync('oka-dup-inv-green-');
      addTearDown(() => root.deleteSync(recursive: true));
      final fixtureDir = Directory(p.join(root.path, 'fixture'))
        ..createSync();
      var index = 0;
      for (final entry in escapeCases.entries) {
        File(p.join(fixtureDir.path, 'escape_$index.dart'))
            .writeAsStringSync(entry.value);
        index++;
      }
      final hits = findDuplicateTrainPackageLists(root);
      expect(
        hits.length,
        escapeCases.length,
        reason: 'expected one hit per escape fixture; got:\n${hits.join('\n')}',
      );
    });

    test('real repo has no duplicate train lists', () {
      expect(findDuplicateTrainPackageLists(Directory(findOkaRepoRoot())), isEmpty);
    });

    test('canonical inventory is not scanned as duplicate', () {
      final repo = findOkaRepoRoot();
      final hits = scanDuplicateTrainPackageListsInSource(
        canonicalTrainInventoryPath,
        File(p.join(repo, canonicalTrainInventoryPath)).readAsStringSync(),
      );
      expect(hits, isEmpty);
    });

    test('flags map literal with train package keys', () {
      final hits = scanDuplicateTrainPackageListsInSource(
        'fixture/map_keys.dart',
        escapeCases['map literal keys']!,
      );
      expect(hits, isNotEmpty);
    });

    test('flags spread-unwrapped train names', () {
      final hits = scanDuplicateTrainPackageListsInSource(
        'fixture/spread.dart',
        escapeCases['spread list elements']!,
      );
      expect(hits, isNotEmpty);
    });

    test('rejects allow comment without reason', () {
      final hits = scanDuplicateTrainPackageListsInSource(
        'fixture/bad_allow.dart',
        '''
void main() {
  // train-inventory-scan: allow
  const v = {
    'oka_process': '1',
    'oka_core': '1',
    'oka_artifacts': '1',
  };
}
''',
      );
      expect(hits, isNotEmpty);
    });

    test('literal allow exempts annotated architecture forbidden sets', () {
      final repo = findOkaRepoRoot();
      final source = File(
        p.join(repo, 'tool/contracts/check_architecture.dart'),
      ).readAsStringSync();
      expect(
        scanDuplicateTrainPackageListsInSource(
          'tool/contracts/check_architecture.dart',
          source,
        ),
        isEmpty,
      );
    });

    test('pasted train inventory at end of architecture file is flagged', () {
      final repo = findOkaRepoRoot();
      final base = File(
        p.join(repo, 'tool/contracts/check_architecture.dart'),
      ).readAsStringSync();
      final injected = '''
$base
const packages = <String>[
  'oka_process',
  'oka_core',
  'oka_artifacts',
  'oka',
];
''';
      final hits = scanDuplicateTrainPackageListsInSource(
        'tool/contracts/check_architecture.dart',
        injected,
      );
      expect(hits, isNotEmpty);
      expect(hits.join('\n'), contains('list literal'));
    });

    test('annotated literal stays exempt beside unannotated duplicate', () {
      final hits = scanDuplicateTrainPackageListsInSource(
        'fixture/arch_mixed.dart',
        '''
void f() {
  // train-inventory-scan: allow architecture forbidden-import set
  const allowed = {
          'oka',
          'oka_web',
          'oka_google_play',
          'oka_app_gallery',
          'oka_huawei',
        };
  const packages = <String>['oka_process', 'oka_core', 'oka_artifacts', 'oka'];
}
''',
      );
      expect(hits, hasLength(1));
      expect(hits.single, contains('list literal'));
    });

    final newFixtures = <String, String>{
      'map literal keys': escapeCases['map literal keys']!,
      'spread list elements': escapeCases['spread list elements']!,
      'allow without reason': '''
void main() {
  // train-inventory-scan: allow
  const v = {'oka_process': '1', 'oka_core': '1', 'oka_artifacts': '1'};
}
''',
    };

    for (final entry in newFixtures.entries) {
      test(
        '0d819ce1 scanner misses ${entry.key}; current scanner flags (mutation)',
        () {
          final rel = 'fixture/mutation_${entry.key.hashCode}.dart';
          final legacy = scanDuplicateTrainPackageListsAt0d819ce1(
            rel,
            entry.value,
          );
          final current = scanDuplicateTrainPackageListsInSource(
            rel,
            entry.value,
          );
          expect(legacy, isEmpty, reason: '0d819ce1 baseline for ${entry.key}');
          expect(current, isNotEmpty, reason: 'current scanner for ${entry.key}');
        },
      );
    }

    test('0d819ce1 file allowlist hid architecture paste on same path', () {
      final repo = findOkaRepoRoot();
      final base = File(
        p.join(repo, 'tool/contracts/check_architecture.dart'),
      ).readAsStringSync();
      final injected = '''
$base
const packages = <String>['oka_process', 'oka_core', 'oka_artifacts', 'oka'];
''';
      expect(
        scanDuplicateTrainPackageListsAt0d819ce1(
          'tool/contracts/check_architecture.dart',
          injected,
        ),
        isEmpty,
      );
      expect(
        scanDuplicateTrainPackageListsInSource(
          'tool/contracts/check_architecture.dart',
          injected,
        ),
        isNotEmpty,
      );
    });

    test('train inventory packages count >= 3 for fixture validity', () {
      expect(packages.length, greaterThanOrEqualTo(3));
    });

    final ifForEscapeCases = <String, String>{
      'if-then only': '''
void main() {
  const v = <String>[
    if (true) 'oka_process',
    if (true) 'oka_core',
    if (true) 'oka_artifacts',
  ];
}
''',
      'if-else split': '''
void main() {
  const v = <String>[
    if (true) 'oka_process' else 'oka_core',
    'oka_artifacts',
  ];
}
''',
      'nested if-in-spread': '''
void main() {
  const v = <String>[
    ...[
      if (true) 'oka_process',
      if (true) 'oka_core',
    ],
    'oka_artifacts',
  ];
}
''',
      'for-element body': '''
void main() {
  const v = <String>[
    for (final _ in <int>[1]) 'oka_process',
    for (final _ in <int>[2]) 'oka_core',
    for (final _ in <int>[3]) 'oka_artifacts',
  ];
}
''',
      'map-entry inside if': '''
void main() {
  const v = <String, String>{
    if (true) 'oka_process': '1',
    'oka_core': '1',
    'oka_artifacts': '1',
  };
}
''',
    };

    for (final entry in ifForEscapeCases.entries) {
      test('flags if/for escape: ${entry.key}', () {
        final rel = 'fixture/if_for_${entry.key.hashCode}.dart';
        final hits = scanDuplicateTrainPackageListsInSource(rel, entry.value);
        expect(hits, isNotEmpty, reason: 'expected violation for ${entry.key}');
      });

      test('if/for escape allow exempts: ${entry.key}', () {
        final rel = 'fixture/if_for_allow_${entry.key.hashCode}.dart';
        final withAllow = entry.value.replaceFirst(
          '  const v =',
          '  // train-inventory-scan: allow test fixture\n'
          '  const v =',
        );
        expect(
          scanDuplicateTrainPackageListsInSource(rel, withAllow),
          isEmpty,
        );
      });

      test(
        'mutation pre-if-for misses ${entry.key}; current flags',
        () {
          final rel = 'fixture/mutation_if_for_${entry.key.hashCode}.dart';
          expect(
            scanDuplicateTrainPackageListsPreIfForUnwrap(rel, entry.value),
            isEmpty,
            reason: 'pre-if/for baseline should miss ${entry.key}',
          );
          expect(
            scanDuplicateTrainPackageListsInSource(rel, entry.value),
            isNotEmpty,
            reason: 'current scanner should flag ${entry.key}',
          );
        },
      );
    }
  });
}
