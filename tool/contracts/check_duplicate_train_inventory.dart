import 'dart:io';

import '../../test/support/repo_root.dart';
import 'duplicate_train_inventory_scan.dart';

Never _fail(String message) {
  stderr.writeln('check_duplicate_train_inventory: $message');
  exit(1);
}

void main() {
  final root = Directory(Platform.environment['OKA_ROOT'] ?? findOkaRepoRoot());
  final offenders = findDuplicateTrainPackageLists(root);
  if (offenders.isNotEmpty) {
    _fail(
      'train package list must live only in $canonicalTrainInventoryPath:\n'
      '${offenders.join('\n')}',
    );
  }
  stdout.writeln('check_duplicate_train_inventory: ok');
}
