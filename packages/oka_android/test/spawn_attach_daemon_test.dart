import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  test('spawnAttachDaemon uses flutterAttachArgv verbatim', () async {
    List<String>? seenArgv;
    final argv = flutterAttachMachineArgs(
      deviceId: 'emulator-5554',
      deviceVmServicePort: 43239,
      hostVmServicePort: 36605,
    );
    final transport = await spawnAttachDaemon(
      flutterBinary: '/nonexistent/flutter',
      flutterAttachArgv: argv,
      processStartForTest: (exe, args, {environment}) {
        seenArgv = args;
        return Process.start(
          Platform.executable,
          ['-e', ''],
          workingDirectory: Directory.systemTemp.path,
        );
      },
    );
  expect(transport, isA<ProcessDaemonTransport>());
    final hostIdx = seenArgv!.indexOf('--host-vmservice-port');
    expect(hostIdx, greaterThanOrEqualTo(0));
    expect(seenArgv![hostIdx + 1], '36605');
    transport.kill();
  });
}
