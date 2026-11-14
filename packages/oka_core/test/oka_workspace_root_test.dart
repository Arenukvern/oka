import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('findOkaWorkspaceRoot resolves anchor without Directory.current', () {
    final root = findOkaWorkspaceRoot();
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
