import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Linux host probe recognizes the current PID and a reaped child as dead',
    () async {
      const liveness = HostProcessLiveness();

      expect(await liveness.isAlive(pid), isTrue);

      final child = await Process.start('sleep', ['30']);
      var reaped = false;
      try {
        expect(await liveness.isAlive(child.pid), isTrue);
        expect(child.kill(), isTrue);
        await child.exitCode;
        reaped = true;

        expect(await liveness.isAlive(child.pid), isFalse);
      } finally {
        if (!reaped) {
          child.kill(ProcessSignal.sigkill);
          await child.exitCode;
        }
      }
    },
    skip: !Platform.isLinux,
  );
}
