// ADR-0011 H3 — the `oka dev` session layer against scripted fakes: the
// daemon protocol via the fake transport (no real flutter), the control
// surface (keyboard / stdin lines / watch routing), device selection over
// an injectable process runner (no real adb), and the flow loop. The live
// emulator e2e tier is recorded in PHASE_CHECKLIST.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  group('control command tables', () {
    test('human keyboard loop: r/R/q/d', () {
      expect(devCommandFromKey('r'), DevControlCommand.reload);
      expect(devCommandFromKey('R'), DevControlCommand.restart);
      expect(devCommandFromKey('q'), DevControlCommand.quit);
      expect(devCommandFromKey('d'), DevControlCommand.detach);
      expect(devCommandFromKey('x'), isNull);
    });
    test('json stdin lines: reload/restart/stop/detach/quit', () {
      expect(devCommandFromLine('reload'), DevControlCommand.reload);
      expect(devCommandFromLine(' restart '), DevControlCommand.restart);
      expect(devCommandFromLine('stop'), DevControlCommand.stopApp);
      expect(devCommandFromLine('detach'), DevControlCommand.detach);
      expect(devCommandFromLine('quit'), DevControlCommand.quit);
      expect(devCommandFromLine('exit'), DevControlCommand.quit);
      expect(devCommandFromLine('bogus'), isNull);
    });
  });

  group('selectDevDevice (injectable runner, no real adb)', () {
    Future<DevDeviceSelection> selectListing(
      final String listing, {
      final String? deviceId,
    }) {
      final tool = AdbTool(
        adbPath: 'fake-adb',
        runProcess: (final exe, final args) async =>
            ProcessResult(0, 0, listing, ''),
      );
      return selectDevDevice(deviceId: deviceId, tool: tool);
    }

    test('one ready device is auto-selected', () async {
      final r = await selectListing(
        'List of devices attached\n'
        'emulator-5554\tdevice product:sdk_gphone64_arm64 '
        'model:sdk_gphone64_arm64 transport_id:1\n',
      );
      expect(r.ok, isTrue);
      expect(r.device!.id, 'emulator-5554');
    });

    test('zero devices refuse with the fix', () async {
      final r = await selectListing('List of devices attached\n\n');
      expect(r.ok, isFalse);
      expect(r.refusal, contains('No ready device'));
      expect(r.refusal, contains('emulator -avd'));
    });

    test(
      'attached-but-not-ready devices are named, not silently ignored',
      () async {
        final r = await selectListing(
          'List of devices attached\n'
          'R58M30ABCDEF\tunauthorized usb:1-1 transport_id:1\n',
        );
        expect(r.ok, isFalse);
        expect(r.refusal, contains('1 attached but not ready'));
      },
    );

    test('multiple ready devices refuse naming them + the -d fix', () async {
      final r = await selectListing(
        'List of devices attached\n'
        'emulator-5554\tdevice model:Pixel_A\n'
        'emulator-5556\tdevice model:Pixel_B\n',
      );
      expect(r.ok, isFalse);
      expect(r.refusal, contains('-d <device-id>'));
      expect(r.refusal, contains('emulator-5554'));
      expect(r.refusal, contains('emulator-5556'));
    });

    test('-d selects the matching ready device', () async {
      final r = await selectListing(
        'List of devices attached\n'
        'emulator-5554\tdevice model:Pixel_A\n'
        'emulator-5556\tdevice model:Pixel_B\n',
        deviceId: 'emulator-5556',
      );
      expect(r.ok, isTrue);
      expect(r.device!.id, 'emulator-5556');
    });

    test('-d with unknown id refuses listing attached ids', () async {
      final r = await selectListing(
        'List of devices attached\n'
        'emulator-5554\tdevice model:Pixel_A\n',
        deviceId: 'nope-9999',
      );
      expect(r.ok, isFalse);
      expect(r.refusal, contains('No device with id "nope-9999"'));
      expect(r.refusal, contains('emulator-5554'));
    });

    test('-d on a non-ready device maps through classifyAdbFailure', () async {
      final r = await selectListing(
        'List of devices attached\n'
        'R58M30ABCDEF\tunauthorized transport_id:1\n',
        deviceId: 'R58M30ABCDEF',
      );
      expect(r.ok, isFalse);
      expect(r.refusal, contains('unauthorized'));
      expect(r.refusal, contains('Allow USB debugging'));
    });

    test('adb listing failure surfaces the classified refusal', () async {
      final tool = AdbTool(
        adbPath: 'fake-adb',
        runProcess: (final exe, final args) async =>
            ProcessResult(0, 1, '', 'adb: insufficient permissions'),
      );
      final r = await selectDevDevice(tool: tool);
      expect(r.ok, isFalse);
      expect(r.refusal, contains('Device listing failed'));
    });
  });

  group('DevSession (scripted fake protocol)', () {
    /// Drives one session: [script] emits fixture events; [after] feeds
    /// control commands while the session runs and may assert on output.
    /// Returns the outcome, captured output lines, and command lines sent
    /// to the daemon.
    Future<(DevSessionOutcome, List<String>, List<String>)> drive({
      required final void Function(FakeDaemonTransport t) script,
      required final Future<void> Function(
        FakeDaemonTransport t,
        StreamController<DevControlCommand> control,
        List<String> lines,
      )
      after,
      final bool json = false,
      final bool rebuildOnNative = false,
      final Object? Function(String method)? respondTo,
      final Object? Function(String method)? respondErrorTo,
    }) async {
      final lines = <String>[];
      final t = FakeDaemonTransport()
        ..respondTo = (respondTo ?? (final _) => const <String, Object?>{})
        ..respondErrorTo = respondErrorTo;
      final control = StreamController<DevControlCommand>.broadcast();
      final session = DevSession(
        adapter: FlutterDaemonAdapter(transport: t),
        session: _session,
        deviceId: 'emulator-5554',
        json: json,
        write: lines.add,
        commands: control.stream,
        rebuildOnNative: rebuildOnNative,
        startupTimeout: const Duration(seconds: 5),
      );
      script(t);
      final done = Completer<DevSessionOutcome>();
      unawaited(session.run().then(done.complete, onError: done.completeError));
      await Future<void>.delayed(Duration.zero);
      await after(t, control, lines);
      final outcome = await done.future.timeout(const Duration(seconds: 10));
      t.exitWith(0);
      await control.close();
      return (outcome, lines, t.sent);
    }

    Iterable<String> methodsOf(final List<String> sent) => sent
        .map(
          (final l) =>
              ((jsonDecode(l) as List).single as Map)['method'] as String,
        )
        .toList();

    test('json mode emits the structured agent stream', () async {
      final (outcome, lines, _) = await drive(
        script: (final t) => t.emitStartup(),
        after: (final t, final control, final lines) async {
          await Future<void>.delayed(Duration.zero);
          expect(
            lines.where((final l) => l.contains('"event":"session.ready"')),
            hasLength(1),
          );
          expect(
            lines.any(
              (final l) =>
                  l.contains('"event":"daemon.app.debugPort"') &&
                  l.contains('wsUri'),
            ),
            isTrue,
            reason:
                'agent stream must carry daemon events: '
                '${lines.join('\n')}',
          );
          expect(
            lines.any((final l) => l.startsWith('⏳') || l.startsWith('🚀')),
            isFalse,
            reason: 'json mode is structured only — no TUI rendering',
          );
          control.add(DevControlCommand.quit);
        },
        json: true,
      );
      expect(outcome, DevSessionOutcome.quit, reason: lines.join('\n'));
    });

    test('programmatic reload works headless (agent acceptance)', () async {
      final (outcome, lines, sent) = await drive(
        script: (final t) => t.emitStartup(),
        after: (final t, final control, final lines) async {
          await Future<void>.delayed(Duration.zero);
          control.add(DevControlCommand.reload);
          await Future<void>.delayed(Duration.zero);
          control.add(DevControlCommand.quit);
        },
        json: true,
      );
      expect(outcome, DevSessionOutcome.quit);
      expect(
        lines.join('\n'),
        contains('"event":"reload.result"'),
        reason: lines.join('\n'),
      );
      final methods = methodsOf(sent);
      expect(methods, containsAllInOrder(['app.reload', 'app.stop']));
    });

    test('human mode: reload dispatch + branded success line', () async {
      final (outcome, lines, sent) = await drive(
        script: (final t) => t.emitStartup(),
        after: (final t, final control, final lines) async {
          await Future<void>.delayed(Duration.zero);
          control.add(DevControlCommand.reload);
          await Future<void>.delayed(Duration.zero);
          control.add(DevControlCommand.detach);
        },
      );
      expect(outcome, DevSessionOutcome.detached);
      expect(lines, contains('🔁 Reload…'));
      expect(lines, contains('✅ Reload complete.'));
      final methods = methodsOf(sent);
      expect(methods, contains('app.reload'));
      expect(
        methods,
        isNot(contains('app.stop')),
        reason: 'detach leaves the app running',
      );
    });

    test('quit stops the app', () async {
      final (outcome, _, sent) = await drive(
        script: (final t) => t.emitStartup(),
        after: (final t, final control, final lines) async {
          await Future<void>.delayed(Duration.zero);
          control.add(DevControlCommand.quit);
        },
      );
      expect(outcome, DevSessionOutcome.quit);
      expect(methodsOf(sent), contains('app.stop'));
      expect(methodsOf(sent), contains('daemon.shutdown'));
    });

    test(
      'reload failure response renders an agent-actionable message',
      () async {
        final (outcome, lines, _) = await drive(
          script: (final t) => t.emitStartup(),
          after: (final t, final control, final lines) async {
            await Future<void>.delayed(Duration.zero);
            control.add(DevControlCommand.reload);
            await Future<void>.delayed(Duration.zero);
            control.add(DevControlCommand.quit);
          },
          respondErrorTo: (final method) =>
              method == 'app.reload' ? 'Observable wipe failed' : null,
        );
        expect(outcome, DevSessionOutcome.quit);
        final out = lines.join('\n');
        expect(out, contains('❌ Reload failed'));
        expect(out, contains('Observable wipe failed'));
        expect(out, contains('fix:'));
      },
    );

    test('app.reloadRecommended renders the oka-branded tip', () async {
      final (outcome, lines, _) = await drive(
        script: (final t) {
          t.emitStartup();
          t.emitEvent('app.reloadRecommended', {
            'reason': 'Files were changed outside of the running session',
          });
        },
        after: (final t, final control, final lines) async {
          await Future<void>.delayed(Duration.zero);
          control.add(DevControlCommand.quit);
        },
      );
      expect(outcome, DevSessionOutcome.quit);
      final out = lines.join('\n');
      expect(out, contains('recommends a reload'));
      expect(out, contains('press `r`'));
    });

    test('rebuildRouting without --rebuild-on-native prints the exact '
        'command and keeps the session', () async {
      final (outcome, lines, _) = await drive(
        script: (final t) => t.emitStartup(),
        after: (final t, final control, final lines) async {
          await Future<void>.delayed(Duration.zero);
          control.add(DevControlCommand.rebuildRouting);
          await Future<void>.delayed(Duration.zero);
          control.add(DevControlCommand.quit);
        },
      );
      expect(outcome, DevSessionOutcome.quit);
      final out = lines.join('\n');
      expect(out, contains(fullRebuildMessage()));
      expect(out, contains('oka build apk --debug'));
      expect(out, contains('--rebuild-on-native'));
    });

    test('rebuildRouting with --rebuild-on-native ends the session for '
        'the rebuild', () async {
      final (outcome, lines, _) = await drive(
        script: (final t) => t.emitStartup(),
        after: (final t, final control, final lines) async {
          await Future<void>.delayed(Duration.zero);
          control.add(DevControlCommand.rebuildRouting);
        },
        rebuildOnNative: true,
      );
      expect(outcome, DevSessionOutcome.rebuildRequested);
      expect(lines.join('\n'), contains('full rebuild'));
    });

    test('daemon exit ends the session as daemonExited', () async {
      final (outcome, lines, _) = await drive(
        script: (final t) {
          t.emitStartup();
          t.exitWith(255);
        },
        after: (final t, final control, final lines) async {},
      );
      expect(outcome, DevSessionOutcome.daemonExited);
      expect(
        lines.join('\n'),
        isNot(contains('Connected')),
        reason: lines.join('\n'),
      );
    });

    test('no app.start within timeout → actionable refusal', () async {
      final lines = <String>[];
      final t = FakeDaemonTransport();
      final session = DevSession(
        adapter: FlutterDaemonAdapter(transport: t),
        session: _session,
        deviceId: 'emulator-5554',
        json: false,
        write: lines.add,
        startupTimeout: const Duration(milliseconds: 50),
      );
      final done = Completer<DevSessionOutcome>();
      unawaited(session.run().then(done.complete, onError: done.completeError));
      final outcome = await done.future.timeout(const Duration(seconds: 10));
      t.exitWith(0);
      expect(outcome, DevSessionOutcome.daemonExited);
      final out = lines.join('\n');
      expect(out, contains('app.start'));
      expect(out, contains('debug build running'));
    });

    test('fullRebuildMessage names the exact commands', () {
      final m = fullRebuildMessage();
      expect(m, contains('oka build apk --debug'));
      expect(m, contains('oka run device'));
      expect(m, contains('Dart-only'));
    });
  });

  group('DevFlow (session → rebuild → re-attach)', () {
    test('rebuildRequested runs the build then re-attaches', () async {
      var builds = 0;
      var sessions = 0;
      final controllers = <StreamController<DevControlCommand>>[];
      final flow = DevFlow(
        prepare: () async {
          sessions++;
          final t = FakeDaemonTransport()
            ..respondTo = (final _) => const <String, Object?>{};
          final control = StreamController<DevControlCommand>.broadcast();
          controllers.add(control);
          final session = DevSession(
            adapter: FlutterDaemonAdapter(transport: t),
            session: _session,
            deviceId: 'emulator-5554',
            json: false,
            write: (_) {},
            commands: control.stream,
            rebuildOnNative: true,
            startupTimeout: const Duration(seconds: 5),
          );
          t.emitStartup();
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 10)).then((_) {
              control.add(
                sessions == 1
                    ? DevControlCommand.rebuildRouting
                    : DevControlCommand.quit,
              );
            }),
          );
          return session;
        },
        runBuild: () async {
          builds++;
          return true;
        },
      );
      final code = await flow.run().timeout(const Duration(seconds: 10));
      for (final c in controllers) {
        await c.close();
      }
      expect(code, 0);
      expect(sessions, 2, reason: 'one attach, then re-attach after rebuild');
      expect(builds, 1);
    });

    test('build failure stops the flow with exit code 1', () async {
      final controllers = <StreamController<DevControlCommand>>[];
      final flow = DevFlow(
        prepare: () async {
          final t = FakeDaemonTransport()
            ..respondTo = (final _) => const <String, Object?>{};
          final control = StreamController<DevControlCommand>.broadcast();
          controllers.add(control);
          unawaited(
            Future<void>.delayed(const Duration(milliseconds: 10)).then((_) {
              control.add(DevControlCommand.rebuildRouting);
            }),
          );
          return DevSession(
            adapter: FlutterDaemonAdapter(transport: t),
            session: _session,
            deviceId: 'emulator-5554',
            json: false,
            write: (_) {},
            commands: control.stream,
            rebuildOnNative: true,
            startupTimeout: const Duration(seconds: 5),
          );
        },
        runBuild: () async => false,
      );
      final code = await flow.run().timeout(const Duration(seconds: 10));
      for (final c in controllers) {
        await c.close();
      }
      expect(code, 1);
    });
  });
}
