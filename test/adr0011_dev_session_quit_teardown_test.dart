import 'dart:async';
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

import '../packages/oka_android/test/support/fake_daemon_transport.dart';

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

AdbArgvRunner fakeAdbHealthy({
  required List<List<String>> calls,
  bool pidofAbsentAfterForceStop = true,
  bool pidofUnknownStderr = false,
}) {
  var forceStopped = false;
  var removedForward = false;

  return (String adb, List<String> args) async {
    calls.add(List<String>.from(args));
    if (args.contains('echo')) {
      return ProcessResult(0, 0, '$adbShellSentinelToken\n', '');
    }
    if (args.contains('pidof')) {
      if (pidofUnknownStderr) {
        return ProcessResult(0, 1, '', 'pidof: warning: odd');
      }
      if (forceStopped && pidofAbsentAfterForceStop) {
        return ProcessResult(0, 1, '', '');
      }
      return ProcessResult(0, 0, '2414\n', '');
    }
    if (args.contains('force-stop')) {
      forceStopped = true;
      return ProcessResult(0, 0, '', '');
    }
    if (args.contains('--list')) {
      if (removedForward) {
        return ProcessResult(0, 0, '', '');
      }
      return ProcessResult(
        0,
        0,
        'emu tcp:34381 tcp:35699\n',
        '',
      );
    }
    if (args.contains('--remove')) {
      removedForward = true;
      return ProcessResult(0, 0, '', '');
    }
    return ProcessResult(0, 0, '', '');
  };
}

DevSessionResourceOwnership _ownership(AdbArgvRunner runAdb) =>
    DevSessionResourceOwnership(
      adbPath: '/fake/adb',
      runAdb: runAdb,
      launchIdentity: const DevSessionLaunchIdentity(
        deviceSerial: 'emu',
        packageName: 'com.example.app',
      ),
      vmServiceForward: DevSessionCreatedForward(
        deviceSerial: 'emu',
        hostLocalPort: 34381,
        deviceRemotePort: 35699,
        recordedAt: DateTime.utc(2026, 11, 8),
      ),
    );

Future<(DevSession, Future<DevSessionOutcome>)> _runningSession({
  required FakeDaemonTransport t,
  required StreamController<DevControlCommand> control,
  required DevSessionResourceOwnership ownership,
  bool noAppStopEvent = false,
  Duration teardownBudgetTotal = kDevSessionTeardownBudgetTotal,
}) async {
  if (noAppStopEvent) {
    t.emitAppStopEventOnStop = false;
  }
  final session = DevSession(
    adapter: FlutterDaemonAdapter(transport: t),
    session: _session,
    deviceId: 'emu',
    json: false,
    write: (_) {},
    commands: control.stream,
    startupTimeout: const Duration(seconds: 5),
    resourceOwnership: ownership,
    teardownBudgetTotal: teardownBudgetTotal,
  );
  t.emitStartup();
  final done = session.run();
  await Future<void>.delayed(const Duration(milliseconds: 80));
  return (session, done);
}

void main() {
  group('DevSession quit teardown behavior', () {
    test('no app.stop event runs force-stop then pidof absent', () async {
      final calls = <List<String>>[];
      final runAdb = fakeAdbHealthy(calls: calls);
      final t = FakeDaemonTransport();
      final control = StreamController<DevControlCommand>.broadcast();
      final (session, done) = await _runningSession(
        t: t,
        control: control,
        ownership: _ownership(runAdb),
        noAppStopEvent: true,
      );
      control.add(DevControlCommand.quit);
      await done.timeout(const Duration(seconds: 15));
      final report = session.lastTeardownReport;
      expect(report, isNotNull);
      expect(report!.forceStop?.commandOk, isTrue);
      expect(report.pidofWait?.absentObserved, isTrue);
      expect(calls.any((a) => a.contains('force-stop')), isTrue);
      expect(calls.any((a) => a.contains('pidof')), isTrue);
      await control.close();
    });

    test('pidof unknown stderr fails cleanup (DevFlow exit 1)', () async {
      final calls = <List<String>>[];
      final runAdb = fakeAdbHealthy(
        calls: calls,
        pidofUnknownStderr: true,
      );
      final t = FakeDaemonTransport();
      final control = StreamController<DevControlCommand>.broadcast();
      final flow = DevFlow(
        prepare: () async {
          final (session, _) = await _runningSession(
            t: t,
            control: control,
            ownership: _ownership(runAdb),
            noAppStopEvent: true,
          );
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 30)).then((_) {
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

    test('detach skips app adb but releases owned forward', () async {
      final calls = <List<String>>[];
      final runAdb = fakeAdbHealthy(calls: calls);
      final t = FakeDaemonTransport();
      final control = StreamController<DevControlCommand>.broadcast();
      final (session, done) = await _runningSession(
        t: t,
        control: control,
        ownership: _ownership(runAdb),
      );
      control.add(DevControlCommand.detach);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      t.exitWith(0);
      await done.timeout(const Duration(seconds: 15));
      expect(session.lastTeardownReport?.appStop, isNull);
      expect(session.lastTeardownReport?.forceStop, isNull);
      expect(session.lastTeardownReport?.pidofWait, isNull);
      expect(calls.any((a) => a.contains('--remove')), isTrue);
      expect(calls.any((a) => a.contains('pidof')), isFalse);
      expect(calls.any((a) => a.contains('force-stop')), isFalse);
      await control.close();
    });

    test('long session wall time does not consume teardown budget before detach',
        () async {
      final calls = <List<String>>[];
      final runAdb = fakeAdbHealthy(calls: calls);
      final t = FakeDaemonTransport();
      final control = StreamController<DevControlCommand>.broadcast();
      final (session, done) = await _runningSession(
        t: t,
        control: control,
        ownership: _ownership(runAdb),
        teardownBudgetTotal: const Duration(seconds: 2),
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      control.add(DevControlCommand.detach);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      t.exitWith(0);
      await done.timeout(const Duration(seconds: 15));
      expect(session.lastTeardownReport?.budgetExhausted, isFalse);
      expect(calls.any((a) => a.contains('--remove')), isTrue);
      await control.close();
    });
  });
}
