import 'dart:io';

import 'package:path/path.dart' as p;

import '../../test/support/repo_root.dart';

Never _fail(String message) {
  stderr.writeln('check_oka_core_barrel_workspace_leak: $message');
  exit(1);
}

void main() {
  final root = Platform.environment['OKA_ROOT'] ?? findOkaRepoRoot();
  final barrel = File(
    p.join(root, 'packages', 'oka_core', 'lib', 'oka_core.dart'),
  );
  if (!barrel.existsSync()) {
    _fail('missing ${barrel.path}');
  }
  final text = barrel.readAsStringSync();
  const forbidden = [
    'oka_workspace_root',
    'findOkaWorkspaceRoot',
    'okaWorkspaceRootAnchor',
  ];
  for (final needle in forbidden) {
    if (text.contains(needle)) {
      _fail(
        'packages/oka_core/lib/oka_core.dart must not export monorepo-only '
        'helpers ($needle)',
      );
    }
  }
  final srcFile = File(
    p.join(root, 'packages', 'oka_core', 'lib', 'src', 'oka_workspace_root.dart'),
  );
  if (srcFile.existsSync()) {
    _fail(
      'remove packages/oka_core/lib/src/oka_workspace_root.dart — use '
      'test/support/oka_workspace_root.dart',
    );
  }
  stdout.writeln('check_oka_core_barrel_workspace_leak: ok');
}
