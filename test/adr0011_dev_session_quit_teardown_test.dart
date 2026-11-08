import 'dart:async';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

import 'adr0011_daemon_adapter_test.dart' show FakeDaemonTransport;

const _sessionJson = {
  'schema': 1,
  'oka_version': '0.0.0-test',
  'recorded_at': '2026-09-08T00:00:00.000Z',
  'flutter_sdk_path': '/fake/flutter-sdk',
  'engine_revision': 'f88005a259ba379c2c1156178aa1870936be7b7f',
  'target_file': 'lib/main.dart',
  'build_mode': 'debug',
  'dart_defines': <String, String>{},
  'application_id': 'com.example.example',
  'abis': ['arm64-v8a'],
  'apk_path': '.oka_cache/build/debug/app-debug.apk',
  'flavor': '',
  'track_widget_creation': true,
};

RunSession get _session => RunSession.fromJson(_sessionJson);

void main() {
  group('DevSession quit teardown behavior', () {
    test('no app.stop event records stopEventSeen false', () async {
      final t = FakeDaemonTransport()..emitAppStopEventOnStop = false;
      final control = StreamController<DevControlCommand>.broadcast();
      final session = DevSession(
        adapter: FlutterDaemonAdapter(transport: t),
        session: _session,
        deviceId: 'emulator-5554',
        json: true,
        write: (_) {},
        commands: control.stream,
        startupTimeout: const Duration(seconds: 5),
      );
      t.emitStartup();
      final done = Completer<DevSessionOutcome>();
      unawaited(session.run().then(done.complete, onError: done.completeError));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      control.add(DevControlCommand.quit);
      final outcome = await done.future.timeout(const Duration(seconds: 15));
      expect(outcome, DevSessionOutcome.quit);
      expect(session.lastTeardownReport?.appStop?.stopEventSeen, isFalse);
      await control.close();
    });

    test('DevFlow quit exits 1 when cleanup actions fail', () async {
      final t = FakeDaemonTransport();
      final control = StreamController<DevControlCommand>.broadcast();
      final flow = DevFlow(
        prepare: () async {
          t.emitStartup();
          final session = DevSession(
            adapter: FlutterDaemonAdapter(transport: t),
            session: _session,
            deviceId: 'emu',
            json: false,
            write: (_) {},
            commands: control.stream,
            startupTimeout: const Duration(seconds: 5),
            resourceOwnership: DevSessionResourceOwnership(
              adbPath: '/nonexistent/adb/xyzzy',
              vmServiceForward: DevSessionCreatedForward(
                deviceSerial: 'emu',
                hostLocalPort: 1,
                deviceRemotePort: 2,
                recordedAt: DateTime.utc(2026, 11, 8),
              ),
            ),
          );
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 20)).then((_) {
              control.add(DevControlCommand.quit);
            }),
          );
          return session;
        },
        runBuild: () async => true,
      );
      final code = await flow.run().timeout(const Duration(seconds: 20));
      expect(code, 1);
      await control.close();
    });
  });
}
