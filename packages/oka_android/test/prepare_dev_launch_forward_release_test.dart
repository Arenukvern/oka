import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

import 'support/failing_dev_discovery_store.dart';
import 'support/prepare_dev_launch_test_steps.dart';

const _ownedPort = 34381;

List<String> _expectRemoveForward(int port, {String? serial}) => [
  if (serial != null) ...['-s', serial],
  'forward',
  '--remove',
  'tcp:$port',
];

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('oka_prepare_fwd_');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'prepareDevLaunch finally removes forward when handoff write fails',
    () async {
      final adbCalls = <List<String>>[];
      await expectLater(
        prepareDevLaunch(
          projectPath: root.path,
          deviceId: 'emulator-5554',
          adbPath: '/fake/adb',
          discoveryStore: FailingWriteVmUriDiscoveryStore(),
          pipelineStepsForTest: [
            SeedVmForwardLaunchStep(hostLocalPort: _ownedPort),
          ],
          runAdb: (adb, args) async {
            adbCalls.add(List<String>.from(args));
            return ProcessResult(0, 0, '', '');
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(adbCalls, hasLength(1));
      expect(
        adbCalls.single,
        _expectRemoveForward(_ownedPort, serial: 'emulator-5554'),
      );
    },
  );

  test(
    'prepareDevLaunch does not remove forward after successful handoff',
    () async {
      final adbCalls = <List<String>>[];
      final prepared = await prepareDevLaunch(
        projectPath: root.path,
        deviceId: 'emulator-5554',
        adbPath: '/fake/adb',
        pipelineStepsForTest: [
          SeedVmForwardLaunchStep(hostLocalPort: _ownedPort),
        ],
        runAdb: (adb, args) async {
          adbCalls.add(List<String>.from(args));
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(prepared.vmServiceLocalPort, _ownedPort);
      expect(
        adbCalls.where((a) => a.contains('--remove')),
        isEmpty,
      );
    },
  );
}
