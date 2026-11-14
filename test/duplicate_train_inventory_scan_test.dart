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

    test('allowlist documents non-inventory exceptions only', () {
      expect(
        duplicateTrainInventoryAllowlist.map((e) => e.path).toList(),
        ['tool/contracts/check_architecture.dart'],
      );
    });

    test('train inventory packages count >= 3 for fixture validity', () {
      expect(packages.length, greaterThanOrEqualTo(3));
    });
  });
}
