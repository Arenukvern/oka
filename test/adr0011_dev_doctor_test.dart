// ADR-0011 H5 — dev-loop readiness checks for `oka doctor`: session
// manifest present/valid, recorded-SDK flutter binary, device readiness
// (scripted fake adb — no device needed; live tier in PHASE_CHECKLIST).
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _manifest = '''
{
  "schema": 1,
  "oka_version": "0.6.0",
  "recorded_at": "2026-09-08T00:00:00.000Z",
  "flutter_sdk_path": "SDK",
  "engine_revision": "f88005a259ba379c2c1156178aa1870936be7b7f",
  "target_file": "lib/main.dart",
  "build_mode": "debug",
  "dart_defines": {},
  "application_id": "com.example.example",
  "abis": ["arm64-v8a"],
  "apk_path": "app-debug.apk",
  "flavor": "",
  "track_widget_creation": true
}
''';

/// Fixture project: `.oka_cache/build/debug/{app-debug.apk,run_session.json}`
/// with a fake recorded SDK that has a flutter binary, plus a fake adb
/// that reports one ready device.
Future<Directory> fixtureProject({
  final bool withManifest = true,
  final bool withApk = true,
  final bool withBinary = true,

  /// null → no adb script at all; `''` → empty device listing.
  final String? deviceListing =
      'List of devices attached\n'
      'emulator-5554\tdevice model:Pixel_5 transport_id:1\n',
}) async {
  final project = await Directory.systemTemp.createTemp('oka_doctor_fixture');
  final buildDir = Directory(
    p.join(project.path, '.oka_cache', 'build', 'debug'),
  )..createSync(recursive: true);
  if (withApk) {
    File(p.join(buildDir.path, 'app-debug.apk')).writeAsStringSync('apk');
  }
  if (withManifest) {
    File(p.join(buildDir.path, 'run_session.json')).writeAsStringSync(
      _manifest.replaceFirst('SDK', p.join(project.path, 'fake-sdk')),
    );
  }
  if (withBinary) {
    File(p.join(project.path, 'fake-sdk', 'bin', 'flutter'))
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\nexit 0\n');
  }
  if (deviceListing != null) {
    final adb = File(p.join(project.path, 'fake-adb'))
      ..writeAsStringSync(
        '#!/bin/sh\n'
        "echo '$deviceListing'\n"
        'exit 0\n',
      );
    await Process.run('chmod', ['+x', adb.path]);
  }
  return project;
}

void main() {
  late Directory project;
  late String adbPath;

  setUp(() async {
    project = await fixtureProject();
    adbPath = p.join(project.path, 'fake-adb');
  });

  tearDown(() => project.deleteSync(recursive: true));

  test('ready fixture: manifest + recorded binary + ready device', () async {
    final r = await devLoopDoctorChecks(
      projectPath: project.path,
      adbPath: adbPath,
    );
    expect(r.ok, isTrue);
    expect(r.blocking, isFalse);
    final out = r.lines.join('\n');
    expect(out, contains('app-debug.apk'));
    expect(out, contains('target=lib/main.dart'));
    expect(out, contains('mode=debug'));
    expect(out, contains('flutter')); // recorded binary line
    expect(out, contains('emulator-5554 ready for attach'));
  });

  test('no built APK → blocking failure with the rebuild fix', () async {
    final empty = await Directory.systemTemp.createTemp('oka_doctor_empty');
    addTearDown(() => empty.deleteSync(recursive: true));
    final r = await devLoopDoctorChecks(projectPath: empty.path);
    expect(r.ok, isFalse);
    expect(r.blocking, isTrue);
    expect(r.lines.single, contains('oka build apk --debug'));
  });

  test('pre-manifest build → blocking failure', () async {
    File(
      p.join(project.path, '.oka_cache', 'build', 'debug', 'run_session.json'),
    ).deleteSync();
    final r = await devLoopDoctorChecks(
      projectPath: project.path,
      adbPath: adbPath,
    );
    expect(r.ok, isFalse);
    expect(r.blocking, isTrue);
    expect(r.lines.single, contains('run_session.json'));
  });

  test('profile build recorded → refuses (debug-only)', () async {
    final profile = await fixtureProject();
    addTearDown(() => profile.deleteSync(recursive: true));
    final manifest = File(
      p.join(profile.path, '.oka_cache', 'build', 'debug', 'run_session.json'),
    );
    manifest.writeAsStringSync(
      manifest.readAsStringSync().replaceFirst(
        '"build_mode": "debug"',
        '"build_mode": "profile"',
      ),
    );
    final r = await devLoopDoctorChecks(
      projectPath: profile.path,
      adbPath: adbPath,
    );
    expect(r.ok, isFalse);
    expect(r.blocking, isTrue);
    expect(r.lines.single, contains('debug-only'));
  });

  test('missing recorded flutter binary → blocking failure', () async {
    File(p.join(project.path, 'fake-sdk', 'bin', 'flutter')).deleteSync();
    final r = await devLoopDoctorChecks(
      projectPath: project.path,
      adbPath: adbPath,
    );
    expect(r.ok, isFalse);
    expect(r.blocking, isTrue);
    expect(r.lines.last, contains('session flutter binary missing'));
  });

  test('no ready device → advisory failure (not blocking)', () async {
    final emptyDevice = await fixtureProject(deviceListing: '');
    addTearDown(() => emptyDevice.deleteSync(recursive: true));
    final r2 = await devLoopDoctorChecks(
      projectPath: emptyDevice.path,
      adbPath: p.join(emptyDevice.path, 'fake-adb'),
    );
    expect(r2.ok, isFalse);
    expect(r2.blocking, isFalse);
    expect(r2.lines.last, contains('no ready device'));
  });

  test('checkDevice: false skips the device check entirely', () async {
    final r = await devLoopDoctorChecks(
      projectPath: project.path,
      checkDevice: false,
    );
    expect(r.ok, isTrue);
    expect(
      r.lines.any((final l) => l.contains('device')),
      isFalse,
      reason: r.lines.join('\n'),
    );
  });
}
