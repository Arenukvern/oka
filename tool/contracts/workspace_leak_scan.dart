import 'dart:io';

import 'package:path/path.dart' as p;

import '../release/train_inventory.dart';

final _importExportLine = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
);

/// Package names scanned by [scanTrainPackageLibsForWorkspaceLeaks] — the
/// release-train inventory from [packages] / `dart tool/release/train.dart list`.
Iterable<String> trainPackagesForWorkspaceLeakScan() => packages;

/// Human-readable violations (paths relative to [root]).
List<String> scanTrainPackageLibsForWorkspaceLeaks(
  Directory root, {
  Iterable<String>? inventoryOverride,
}) {
  final inventory = inventoryOverride ?? trainPackagesForWorkspaceLeakScan();
  final violations = <String>[];
  for (final pkg in inventory) {
    final libDir = Directory(p.join(root.path, 'packages', pkg, 'lib'));
    if (!libDir.existsSync()) continue;
    for (final file in libDir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      if (file.path.contains('${p.separator}.dart_tool${p.separator}')) {
        continue;
      }
      final rel = p.relative(file.path, from: root.path).replaceAll(r'\', '/');
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final match = _importExportLine.firstMatch(line);
        if (match == null) continue;
        final uri = match.group(1)!;
        if (_isForbiddenPublishedLibUri(uri) ||
            line.contains('findOkaWorkspaceRoot')) {
          violations.add('$rel:${i + 1}: ${line.trim()}');
        }
      }
    }
  }
  final resurrected = p.join(
    'packages',
    'oka_core',
    'lib',
    'src',
    'oka_workspace_root.dart',
  );
  if (File(p.join(root.path, resurrected)).existsSync()) {
    violations.add(
      '$resurrected exists — use test/support/oka_workspace_root.dart',
    );
  }
  violations.sort();
  return violations;
}

bool _isForbiddenPublishedLibUri(String uri) {
  final norm = uri.replaceAll(r'\', '/');
  if (norm.contains('test/support')) return true;
  if (norm.contains('oka_workspace_root')) return true;
  if (norm.contains('repo_root.dart') && norm.contains('test/')) return true;
  return false;
}
