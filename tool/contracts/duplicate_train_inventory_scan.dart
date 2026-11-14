import 'dart:io';

import 'package:path/path.dart' as p;

/// Canonical inventory — the only file that may define `const packages = ...`.
const canonicalTrainInventoryPath = 'tool/release/train_inventory.dart';

final duplicateTrainPackageListPatterns = <RegExp>[
  RegExp(r'const\s+packages\s*=\s*<String>\s*\['),
  RegExp(r'const\s+trainPackages\s*=\s*\['),
  RegExp(r'trainPackagesForWorkspaceLeakScan\s*=\s*<String>\s*\['),
];

/// Dart files under [root] (excluding [canonicalTrainInventoryPath]) that
/// appear to embed a second hard-coded train package list.
List<String> findDuplicateTrainPackageLists(Directory root) {
  final offenders = <String>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final rel = p.relative(entity.path, from: root.path).replaceAll(r'\', '/');
    if (rel == canonicalTrainInventoryPath) continue;
    if (rel.contains('/.dart_tool/') ||
        rel.startsWith('build/') ||
        rel.contains('/build/')) {
      continue;
    }
    final lines = entity.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('//')) continue;
      for (final pattern in duplicateTrainPackageListPatterns) {
        if (pattern.hasMatch(line)) {
          offenders.add('$rel:${i + 1}: ${line.trim()}');
          break;
        }
      }
    }
  }
  offenders.sort();
  return offenders;
}
