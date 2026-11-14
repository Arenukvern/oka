import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/oka_workspace_root.dart';
import 'support/repo_root.dart';

void main() {
  test('findOkaWorkspaceRoot resolves anchor without Directory.current', () {
    final root = findOkaRepoRoot();
    expect(
      File(p.join(root, okaWorkspaceRootAnchor)).existsSync(),
      isTrue,
      reason: 'resolved root must contain $okaWorkspaceRootAnchor',
    );
    expect(
      File(p.join(root, 'pubspec.yaml')).readAsStringSync(),
      contains('name: oka_workspace'),
    );
  });
}
