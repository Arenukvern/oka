import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/contracts/workspace_leak_scan.dart';
import '../tool/release/train_inventory.dart' as train_inventory;
import 'support/repo_root.dart';

void main() {
  final realRoot = Directory(findOkaRepoRoot());

  test('scanner inventory matches dart tool/release/train.dart list', () {
    final repo = findOkaRepoRoot();
    final result = Process.runSync(
      Platform.executable,
      [p.join(repo, 'tool/release/train.dart'), 'list'],
      workingDirectory: repo,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final listed = result.stdout
        .toString()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    final scanned = trainPackagesForWorkspaceLeakScan().toList();
    expect(scanned, listed);
    expect(scanned, train_inventory.packages);
  });

  test('real train packages have no workspace-leak imports in lib/', () {
    expect(
      scanTrainPackageLibsForWorkspaceLeaks(realRoot),
      isEmpty,
    );
  });

  test('detects lib/src re-export of test/support', () {
    final root = Directory.systemTemp.createTempSync('oka-ws-leak-');
    addTearDown(() => root.deleteSync(recursive: true));
    final srcDir = Directory(
      p.join(root.path, 'packages', 'fake_pkg', 'lib', 'src'),
    )..createSync(recursive: true);
    File(p.join(srcDir.path, 'leak.dart')).writeAsStringSync(
      "export '../../../../test/support/oka_workspace_root.dart';\n",
    );
    File(p.join(root.path, 'packages', 'fake_pkg', 'lib', 'fake_pkg.dart'))
        .writeAsStringSync("export 'src/leak.dart';\n");
    final hits = scanTrainPackageLibsForWorkspaceLeaks(
      root,
      inventoryOverride: const ['fake_pkg'],
    );
    expect(hits, isNotEmpty);
    expect(hits.join('\n'), contains('test/support'));
  });

  test('detects relative import of test/support from lib/', () {
    final root = Directory.systemTemp.createTempSync('oka-ws-leak-');
    addTearDown(() => root.deleteSync(recursive: true));
    final libDir = Directory(p.join(root.path, 'packages', 'fake_pkg', 'lib'))
      ..createSync(recursive: true);
    File(p.join(libDir.path, 'consumer.dart')).writeAsStringSync('''
import '../../../test/support/repo_root.dart';

void noop() {}
''');
    final hits = scanTrainPackageLibsForWorkspaceLeaks(
      root,
      inventoryOverride: const ['fake_pkg'],
    );
    expect(hits, isNotEmpty);
    expect(hits.single, contains('consumer.dart'));
  });

  test('detects resurrected oka_core lib/src/oka_workspace_root.dart', () {
    final root = Directory.systemTemp.createTempSync('oka-ws-leak-');
    addTearDown(() => root.deleteSync(recursive: true));
    final libDir = Directory(
      p.join(root.path, 'packages', 'oka_core', 'lib', 'src'),
    )..createSync(recursive: true);
    File(p.join(libDir.path, 'oka_workspace_root.dart')).writeAsStringSync(
      '// forbidden\n',
    );
    final hits = scanTrainPackageLibsForWorkspaceLeaks(
      root,
      inventoryOverride: const ['oka_core'],
    );
    expect(
      hits,
      contains(
        'packages/oka_core/lib/src/oka_workspace_root.dart exists — use '
        'test/support/oka_workspace_root.dart',
      ),
    );
  });
}
