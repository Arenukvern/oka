import 'dart:io';

import '../../test/support/repo_root.dart';
import 'workspace_leak_scan.dart';

Never _fail(String message) {
  stderr.writeln('check_train_package_lib_workspace_leak: $message');
  exit(1);
}

void main() {
  final root = Directory(Platform.environment['OKA_ROOT'] ?? findOkaRepoRoot());
  final violations = scanTrainPackageLibsForWorkspaceLeaks(root);
  if (violations.isNotEmpty) {
    _fail(
      'published train package lib/ must not import or export monorepo-only '
      'test/support helpers:\n${violations.join('\n')}',
    );
  }
  stdout.writeln('check_train_package_lib_workspace_leak: ok');
}
