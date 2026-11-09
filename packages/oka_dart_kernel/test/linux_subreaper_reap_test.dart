import 'dart:io';

import 'package:oka_dart_kernel/src/gate/linux_subreaper_reap.dart';
import 'package:test/test.dart';

void main() {
  test(
    'waitpid WNOHANG returns zero when no zombie children',
    () {
      expect(reapAvailableChildZombies(), 0);
    },
    skip: Platform.isLinux ? false : 'linux reap',
  );
}
