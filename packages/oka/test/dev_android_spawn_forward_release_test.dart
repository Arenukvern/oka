import 'dart:convert';
import 'dart:io';

import 'package:oka/src/cli/dev_android_attach.dart';
import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

class _AttachSpawnFailure implements Exception {
  _AttachSpawnFailure();
  @override
  String toString() => 'injected attach spawn failure';
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('oka_spawn_fwd_');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'spawnDevAndroidAttachTransport removes forward when spawn fails',
    () async {
      const prepared = DevLaunchPrepared(
        apkPath: '/tmp/a.apk',
        vmServiceUri: 'ws://127.0.0.1:36605/secret=/ws',
        vmServiceLocalPort: 36605,
        vmServiceDevicePort: 43239,
        vmServiceDeviceDebugUrl: 'http://127.0.0.1:43239/secret=/',
      );
      final attachArgv = buildDevAndroidAttachArgv(
        deviceId: 'emulator-5554',
        prepared: prepared,
      );
      final adbCalls = <List<String>>[];

      await expectLater(
        spawnDevAndroidAttachTransport(
          projectPath: root.path,
          flutterBinary: '/nonexistent/flutter',
          attachArgv: attachArgv,
          adbPath: '/fake/adb',
          deviceId: 'emulator-5554',
          prepared: prepared,
          runAdb: (adb, args) async {
            adbCalls.add(List<String>.from(args));
            return ProcessResult(0, 0, '', '');
          },
          processStartForTest: (_, _, {environment}) =>
              Future<Process>.error(_AttachSpawnFailure()),
        ),
        throwsA(isA<_AttachSpawnFailure>()),
      );

      expect(adbCalls, hasLength(1));
      expect(
        adbCalls.single,
        const [
          '-s',
          'emulator-5554',
          'forward',
          '--remove',
          'tcp:36605',
        ],
      );

      final diag = File(
        '${root.path}/.flutter_mcp/$attachHandshakeDiagnosticFileName',
      );
      expect(diag.existsSync(), isTrue);
      final payload = jsonDecode(diag.readAsStringSync()) as Map<String, Object?>;
      expect(payload['forwardReleased'], isTrue);
      expect(payload['kind'], 'attach_spawn_failure');
    },
  );
}
