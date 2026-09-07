// ADR-0011 H2 — device-layer adb tool: command construction, parsers,
// failure classification, and the pipeline steps (scripted fake adb —
// no real device needed; the e2e tier is recorded in PHASE_CHECKLIST).
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

BuildContext _ctx(final String projectPath) => BuildContext(
      projectPath: projectPath,
      buildDir: p.join(projectPath, '.oka_cache', 'build', 'debug'),
      mode: BuildMode.debug,
      config: OkaConfig.empty,
      cacheDir: p.join(projectPath, '.oka_cache'),
    );

/// Writes an executable shell script answering the adb calls (baked-in
/// behavior — the `adr0015_device_target_test` pattern).
Future<String> _fakeAdb(
  final Directory dir,
  final String name,
  final String body,
) async {
  final f = File(p.join(dir.path, name))
    ..writeAsStringSync('#!/bin/sh\n$body');
  await Process.run('chmod', ['+x', f.path]);
  return f.path;
}

const _vmServiceLine =
    'I/flutter ( 4242): Dart VM Service listening on '
    'http://127.0.0.1:41235/AbCdEfGhIj=/';

void main() {
  group('command construction (pure)', () {
    test('devices/install/launch/forward/logcat argv', () {
      expect(adbDevicesArgs(), ['devices', '-l']);
      expect(adbInstallArgs('/x/app.apk'), ['install', '-r', '/x/app.apk']);
      expect(
        adbLaunchArgs('pkg', 'pkg.Act'),
        ['shell', 'am', 'start', '-n', 'pkg/pkg.Act'],
      );
      expect(
        adbForwardArgs(devicePort: 41235),
        ['forward', 'tcp:0', 'tcp:41235'],
      );
      expect(
        adbForwardArgs(devicePort: 41235, hostPort: 8080),
        ['forward', 'tcp:8080', 'tcp:41235'],
      );
      expect(adbLogcatDumpArgs(), ['logcat', '-d']);
      expect(adbLogcatClearArgs(), ['logcat', '-c']);
    });
  });

  group('parseAdbDevices (recorded fixture shapes)', () {
    test('empty listing', () {
      expect(
        parseAdbDevices('List of devices attached\n\n'),
        isEmpty,
      );
    });

    test('daemon noise is ignored', () {
      final out = parseAdbDevices(
        '* daemon not running; starting now at tcp:5037\n'
        '* daemon started successfully\n'
        'List of devices attached\n',
      );
      expect(out, isEmpty);
    });

    test('-l long form: id, state, model', () {
      final out = parseAdbDevices(
        'List of devices attached\n'
        'R58M30ABCDEF\tdevice product:flame '
        'model:Pixel_4 device:flame transport_id:1\n'
        'emulator-5554\toffline transport_id:2\n'
        '192.168.1.10:5555\tunauthorized\n',
      );
      expect(out, hasLength(3));
      expect(out[0].id, 'R58M30ABCDEF');
      expect(out[0].state, 'device');
      expect(out[0].model, 'Pixel_4');
      expect(out[0].ready, isTrue);
      expect(out[1].id, 'emulator-5554');
      expect(out[1].ready, isFalse);
      expect(out[2].state, 'unauthorized');
      expect(out[2].model, isEmpty);
    });
  });

  group('parseVmServiceUri (logcat scrape)', () {
    test('parses scheme/host/port/auth from the announcement', () {
      final info = parseVmServiceUri(
        'E/x: noise\n$_vmServiceLine\nW/x: more noise\n',
      );
      expect(info, isNotNull);
      expect(info!.scheme, 'http');
      expect(info.host, '127.0.0.1');
      expect(info.port, 41235);
      expect(info.auth, 'AbCdEfGhIj=');
      expect(info.uri, 'http://127.0.0.1:41235/AbCdEfGhIj=');
      expect(info.wsUri, 'ws://127.0.0.1:41235/AbCdEfGhIj=');
    });

    test('last announcement wins (stale entries in the buffer)', () {
      final info = parseVmServiceUri(
        '$_vmServiceLine\n'
        'I/flutter ( 9999): Dart VM Service listening on '
        'http://127.0.0.1:51111/ZzYyXwVuTt=/\n',
      );
      expect(info!.port, 51111);
      expect(info.auth, 'ZzYyXwVuTt=');
    });

    test('newer Flutter wording ("The Dart VM service is listening on") '
        'matches too — H0 emulator finding', () {
      final info = parseVmServiceUri(
        'I/flutter ( 5910): The Dart VM service is listening on '
        'http://127.0.0.1:38635/ZhBkkcLBabc=/\n',
      );
      expect(info!.port, 38635);
      expect(info.auth, 'ZhBkkcLBabc=');
    });

    test('trailing slash is trimmed from the auth path', () {
      final info = parseVmServiceUri(
        'Dart VM Service listening on http://127.0.0.1:1234/AbCd=/ /',
      );
      expect(info!.auth, 'AbCd=');
      expect(info.uri, 'http://127.0.0.1:1234/AbCd=');
    });

    test('no announcement → null', () {
      expect(parseVmServiceUri('nothing here\n'), isNull);
    });
  });

  group('parseForwardPort', () {
    test('parses the chosen port', () {
      expect(parseForwardPort('41557\n'), 41557);
      expect(parseForwardPort('41557'), 41557);
    });
    test('garbage → null', () {
      expect(parseForwardPort('error: no device'), isNull);
    });
  });

  group('classifyAdbFailure (oka-style next steps)', () {
    test('table', () {
      expect(
        classifyAdbFailure(
          "error: device unauthorized.\nThis adb server's adb_key is not "
          'authorized',
        ).kind,
        'unauthorized',
      );
      expect(
        classifyAdbFailure('error: no devices/emulators found').kind,
        'no-device',
      );
      expect(
        classifyAdbFailure('error: device offline').kind,
        'device-offline',
      );
      expect(
        classifyAdbFailure(
          'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]',
        ).kind,
        'signing-mismatch',
      );
      expect(
        classifyAdbFailure(
          'Failure [INSTALL_FAILED_VERSION_DOWNGRADE]',
        ).kind,
        'install-failed',
      );
      expect(
        classifyAdbFailure('Failure [INSTALL_FAILED_INVALID_APK]').kind,
        'install-failed',
      );
      final unknown = classifyAdbFailure('something entirely new');
      expect(unknown.kind, 'unknown');
      expect(unknown.message, contains('something entirely new'));
    });

    test('every classification names a fix', () {
      for (final raw in [
        'device unauthorized',
        'no devices',
        'device offline',
        'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]',
        'Failure [INSTALL_FAILED_INVALID_APK]',
        'unknown gibberish',
      ]) {
        expect(
          classifyAdbFailure(raw).fix,
          isNotEmpty,
          reason: 'raw output "$raw" must map to a fix',
        );
      }
    });
  });

  group('AdbTool against a scripted fake adb', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_adb_tool_');
    });
    tearDown(() => tmp.delete(recursive: true));

    test('devices() parses the fake listing', () async {
      final adb = await _fakeAdb(
        tmp,
        'adb1',
        r'case "$1" in devices) '
            'echo "List of devices attached"; '
            'echo "emulator-5554\tdevice product:sdk model:sdk_gphone64"; '
            'exit 0;; esac; exit 1',
      );
      final devices = await AdbTool(adbPath: adb).devices();
      expect(devices, hasLength(1));
      expect(devices.single.id, 'emulator-5554');
      expect(devices.single.model, 'sdk_gphone64');
      expect(devices.single.ready, isTrue);
    });

    test('install success; install failure classified with the fix',
        () async {
      final ok = await _fakeAdb(
        tmp,
        'adb2',
        r'case "$1 $2" in "install -r") echo Success; exit 0;; esac; exit 1',
      );
      await AdbTool(adbPath: ok).install('/x/app-debug.apk'); // must not throw

      final bad = await _fakeAdb(
        tmp,
        'adb3',
        r'case "$1 $2" in "install -r") '
            'echo "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]"; exit 1;; '
            'esac; exit 1',
      );
      expect(
        () => AdbTool(adbPath: bad).install('/x/app-debug.apk'),
        throwsA(
          isA<AdbToolException>()
              .having((final e) => e.failure.kind, 'kind', 'signing-mismatch')
              .having((final e) => e.toString(), 'toString',
                  contains('same key')),
        ),
      );
    });

    test('install: exit 0 but "Failure" output is still a failure', () async {
      final lying = await _fakeAdb(
        tmp,
        'adb4',
        r'case "$1 $2" in "install -r") echo "Failure"; exit 0;; esac; exit 1',
      );
      expect(
        () => AdbTool(adbPath: lying).install('/x/app.apk'),
        throwsA(isA<AdbToolException>()),
      );
    });

    test('forwardTcp(hostPort: 0) returns the picked local port', () async {
      final adb = await _fakeAdb(
        tmp,
        'adb5',
        r'case "$1 $2" in "forward tcp:0") echo 41557; exit 0;; esac; exit 1',
      );
      final port = await AdbTool(adbPath: adb).forwardTcp(devicePort: 41235);
      expect(port, 41557);
    });

    test('forwardTcp failure surfaces the classified fix', () async {
      final adb = await _fakeAdb(
        tmp,
        'adb6',
        'echo "error: device offline" >&2; exit 1',
      );
      expect(
        () => AdbTool(adbPath: adb).forwardTcp(devicePort: 1),
        throwsA(
          isA<AdbToolException>().having(
            (final e) => e.failure.kind,
            'kind',
            'device-offline',
          ),
        ),
      );
    });

    test('awaitVmServiceUri finds the announcement (bounded poll)',
        () async {
      final adb = await _fakeAdb(
        tmp,
        'adb7',
        r'case "$1 $2" in "logcat -d") '
            'echo "I/flutter: Dart VM Service listening on '
            'http://127.0.0.1:41235/AbCdEfGhIj=/";; esac; exit 0',
      );
      final info = await AdbTool(adbPath: adb).awaitVmServiceUri(
        timeout: const Duration(seconds: 5),
        pollInterval: const Duration(milliseconds: 10),
      );
      expect(info!.port, 41235);
    });

    test('awaitVmServiceUri times out with null (never hangs)', () async {
      final adb = await _fakeAdb(
        tmp,
        'adb8',
        r'case "$1 $2" in "logcat -d") echo "quiet";; esac; exit 0',
      );
      final sw = Stopwatch()..start();
      final info = await AdbTool(adbPath: adb).awaitVmServiceUri(
        timeout: const Duration(milliseconds: 300),
        pollInterval: const Duration(milliseconds: 50),
      );
      expect(info, isNull);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });
  });

  group('VM-service pipeline steps', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_vm_steps_');
    });
    tearDown(() => tmp.delete(recursive: true));

    test('AwaitVmServiceStep provides the scraped URI', () async {
      final adb = await _fakeAdb(
        tmp,
        'adb9',
        r'case "$1 $2" in "logcat -d") '
            'echo "I/flutter: Dart VM Service listening on '
            'http://127.0.0.1:41235/AbCdEfGhIj=/";; esac; exit 0',
      );
      final step = AwaitVmServiceStep(
        adbPath: adb,
        timeout: const Duration(seconds: 5),
        pollInterval: const Duration(milliseconds: 10),
      );
      final result = await step.run(_ctx(tmp.path), PipelineState());
      expect(result.ok, isTrue);
      expect(result.data[vmServiceUri.id], contains('127.0.0.1:41235'));
    });

    test('AwaitVmServiceStep fails oka-branded on timeout / non-debug hint',
        () async {
      final adb = await _fakeAdb(
        tmp,
        'adb10',
        r'case "$1 $2" in "logcat -d") echo "quiet";; esac; exit 0',
      );
      final result = await AwaitVmServiceStep(
        adbPath: adb,
        timeout: const Duration(milliseconds: 200),
        pollInterval: const Duration(milliseconds: 50),
      ).run(_ctx(tmp.path), PipelineState());
      expect(result.ok, isFalse);
      expect(result.error, contains('debug (JIT)'));
    });

    test('ForwardVmServiceStep forwards the scraped port (chain contract)',
        () async {
      final adb = await _fakeAdb(
        tmp,
        'adb11',
        r'case "$1 $2" in "forward tcp:0") echo 41557; exit 0;; esac; exit 1',
      );
      final state = PipelineState();
      state[vmServiceUri.id] = 'http://127.0.0.1:41235/AbCdEfGhIj=';
      final result = await ForwardVmServiceStep(adbPath: adb).run(
        _ctx(tmp.path),
        state,
      );
      expect(result.ok, isTrue);
      expect(result.data[vmServiceLocalPort.id], 41557);
    });

    test('step chain validates: await → forward (and not reversed)', () {
      final awaitStep = AwaitVmServiceStep();
      final forwardStep = ForwardVmServiceStep();
      expect(
        Pipeline([awaitStep, forwardStep]).validate(),
        isNull,
      );
      final reversed = Pipeline([forwardStep]).validate();
      expect(reversed, isNotNull);
      expect(reversed, contains('vm_service_uri'));
    });

    test('forwardedVmServiceUri rebuilds the host-reachable ws endpoint',
        () {
      final info = parseVmServiceUri(_vmServiceLine)!;
      expect(
        forwardedVmServiceUri(info, 41557),
        'ws://127.0.0.1:41557/AbCdEfGhIj=',
      );
    });
  });
  group('device serial (multi-device hosts)', () {
    test('serial builders prefix -s only when a serial is set', () {
      expect(adbInstallArgs('/tmp/a.apk', serial: 'R5CX'),
          ['-s', 'R5CX', 'install', '-r', '/tmp/a.apk']);
      expect(adbInstallArgs('/tmp/a.apk'), ['install', '-r', '/tmp/a.apk']);
      expect(adbSerialArgs(null), isEmpty);
      expect(adbSerialArgs('  '), isEmpty);
      expect(adbSerialArgs(' emulator-5554 '), ['-s', 'emulator-5554']);
      expect(adbLaunchArgs('p', 'a', serial: 'S1'),
          ['-s', 'S1', 'shell', 'am', 'start', '-n', 'p/a']);
      expect(adbLogcatDumpArgs(serial: 'S1'), ['-s', 'S1', 'logcat', '-d']);
      expect(adbLogcatClearArgs(), ['logcat', '-c']);
      expect(
        adbForwardArgs(devicePort: 4, serial: 'S1'),
        ['-s', 'S1', 'forward', 'tcp:0', 'tcp:4'],
      );
    });

    test('AdbTool threads the serial into every operation', () async {
      final seen = <List<String>>[];
      Future<ProcessResult> fake(String exe, List<String> args) async {
        seen.add(args);
        // `adb forward tcp:0` prints the chosen local port on stdout.
        return ProcessResult(
          0,
          0,
          args.contains('forward') ? '41235\n' : '',
          '',
        );
      }

      final tool = AdbTool(adbPath: 'adb', serial: 'S1', runProcess: fake);
      await tool.install('/tmp/a.apk');
      await tool.launch('p', 'a');
      await tool.clearLogcat();
      await tool.logcatDump();
      await tool.forwardTcp(devicePort: 9);
      expect(seen, [
        ['-s', 'S1', 'install', '-r', '/tmp/a.apk'],
        ['-s', 'S1', 'shell', 'am', 'start', '-n', 'p/a'],
        ['-s', 'S1', 'logcat', '-c'],
        ['-s', 'S1', 'logcat', '-d'],
        ['-s', 'S1', 'forward', 'tcp:0', 'tcp:9'],
      ]);
    });
  });

}
