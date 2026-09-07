// ADR-0015 C1 — `DeviceTarget` (oka_android): the device smoke-test flow
// expressed as a target instead of CLI-verb Android logic.
//
// Covers:
// * target → pipeline compilation validated before any tool runs (the
//   ADR-0015 design law, now for the device flow);
// * step behaviors with scripted fake adb/aapt2 executables (install
//   success/failure classification, badging resolution, launch, logcat
//   failure-signature scan, pid liveness);
// * the pure helpers (`parseAapt2Badging`, `scanLogForFailureSignatures`,
//   `findNewestBuiltApk`).
//
// No real device or SDK is required — the tool invocations are pointed at
// throwaway shell scripts via the steps' injectable paths.
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
      tempDir: p.join(projectPath, '.oka_cache', 'build', 'debug', 'temp'),
    );

/// Writes an executable shell script that answers the adb/aapt2 calls the
/// device steps make. Behavior is baked in at creation time — no env vars,
/// no state.
Future<String> _fakeTool(
  final Directory dir,
  final String name,
  final String body,
) async {
  final f = File(p.join(dir.path, name))
    ..writeAsStringSync('#!/bin/sh\n$body');
  await Process.run('chmod', ['+x', f.path]);
  return f.path;
}

const _adbHappy = r'''
case "$1 $2" in
  "install -r") echo "Success"; exit 0;;
  "logcat -c") exit 0;;
  "logcat -d") exit 0;;
  "shell am") echo "Starting: Intent"; exit 0;;
  "shell pidof") echo "4242"; exit 0;;
esac
exit 1
''';

const _adbCrashLog = r'''
case "$1 $2" in
  "install -r") echo "Success"; exit 0;;
  "logcat -c") exit 0;;
  "logcat -d") echo "E/AndroidRuntime: FATAL EXCEPTION: main"; exit 0;;
  "shell am") echo "Starting: Intent"; exit 0;;
  "shell pidof") echo "4242"; exit 0;;
esac
exit 1
''';

const _adbDeadProcess = r'''
case "$1 $2" in
  "install -r") echo "Success"; exit 0;;
  "logcat -c") exit 0;;
  "logcat -d") exit 0;;
  "shell am") echo "Starting: Intent"; exit 0;;
  "shell pidof") exit 0;;
esac
exit 1
''';

const _adbInstallIncompatible = r'''
case "$1 $2" in
  "install -r") echo "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]"; exit 1;;
esac
exit 1
''';

const _aapt2Badging = r'''
case "$1 $2" in
  "dump badging")
    echo "package: name='com.example.app' versionCode='1' versionName='1.0'"
    echo "launchable-activity: name='com.example.app.MainActivity'  label='Example'"
    exit 0;;
esac
exit 1
''';

void main() {
  group('DeviceTarget compilation (ADR-0015 design law)', () {
    late Directory project;

    setUp(() async {
      project = await Directory.systemTemp.createTemp('oka_device_tgt_');
      addTearDown(() => project.delete(recursive: true));
    });

    test('compiles to a pipeline that validates clean', () {
      final pipeline = Pipeline(const DeviceTarget().compile(_ctx(project.path)));
      expect(pipeline.validate(), isNull);
    });

    test('default flow: resolve → install → launch → scan', () {
      final names =
          const DeviceTarget().compile(_ctx(project.path)).map((s) => s.name);
      expect(
        names,
        ['resolve-device-apk', 'device-install', 'device-launch',
            'device-logcat-scan'],
      );
    });

    test('noInstall drops the install step and keeps a dead process from '
        'failing the run', () {
      final steps =
          const DeviceTarget(noInstall: true).compile(_ctx(project.path));
      expect(steps.map((s) => s.name), isNot(contains('device-install')));
      final scan = steps.whereType<LogcatScanStep>().single;
      expect(scan.treatMissingProcessAsFailure, isFalse);
    });

    test('typed config flows into the compiled steps', () {
      final steps = const DeviceTarget(
        apk: 'x/app.apk',
        package: 'dev.a',
        activity: 'dev.a.Main',
        waitSeconds: 3,
      ).compile(_ctx(project.path));
      expect(steps.whereType<ResolveNewestApkStep>().single.explicitApk,
          'x/app.apk');
      final launch = steps.whereType<LaunchAppStep>().single;
      expect(launch.packageOverride, 'dev.a');
      expect(launch.activityOverride, 'dev.a.Main');
      expect(steps.whereType<LogcatScanStep>().single.waitSeconds, 3);
    });

    test('name survives validateTargetName (device is not a reserved verb)',
        () {
      expect(validateTargetName(const DeviceTarget().name), isNull);
    });
  });

  group('DeviceTarget steps (scripted adb/aapt2)', () {
    late Directory project;
    late Directory tools;
    late String adb;
    late String aapt2;

    setUp(() async {
      project = await Directory.systemTemp.createTemp('oka_device_e2e_');
      tools = await Directory.systemTemp.createTemp('oka_device_tools_');
      adb = await _fakeTool(tools, 'adb', _adbHappy);
      aapt2 = await _fakeTool(tools, 'aapt2', _aapt2Badging);
      addTearDown(() => project.delete(recursive: true));
      addTearDown(() => tools.delete(recursive: true));
    });

    Future<StepResult> runTarget(final DeviceTarget target) {
      final pipeline = Pipeline(target.compile(_ctx(project.path)));
      final validationError = pipeline.validate();
      if (validationError != null) {
        fail('pipeline invalid before running: $validationError');
      }
      return pipeline.run(_ctx(project.path));
    }

    test('happy path: newest APK installed, launched, alive, clean log',
        () async {
      final apk = File(
        p.join(project.path, '.oka_cache', 'build', 'debug', 'app-debug.apk'),
      );
      await apk.parent.create(recursive: true);
      await apk.writeAsBytes(List.filled(16, 1));

      final result = await runTarget(
        DeviceTarget(waitSeconds: 0, adbPath: adb, aapt2Path: aapt2),
      );
      expect(result.ok, isTrue, reason: result.error);
      // The newest built APK is resolved and staged as apk-path.
      expect(result.data['apk_path'] ?? '', endsWith('app-debug.apk'));
    });

    test('explicit apk wins over discovery', () async {
      final explicit = File(p.join(project.path, 'custom.apk'));
      await explicit.writeAsBytes(List.filled(4, 2));
      final result = await runTarget(
        DeviceTarget(
          apk: explicit.path,
          waitSeconds: 0,
          adbPath: adb,
          aapt2Path: aapt2,
        ),
      );
      expect(result.ok, isTrue, reason: result.error);
    });

    test('no APK anywhere fails with the build-first hint', () async {
      final result = await runTarget(DeviceTarget(adbPath: adb));
      expect(result.ok, isFalse);
      expect(result.error, contains('No APK found'));
      expect(result.error, contains('oka build apk'));
    });

    test('install failure with an incompatible signature is classified',
        () async {
      final apk = File(
        p.join(project.path, '.oka_cache', 'build', 'debug', 'app-debug.apk'),
      );
      await apk.parent.create(recursive: true);
      await apk.writeAsBytes(List.filled(8, 3));
      final incompatible = await _fakeTool(tools, 'adb2',
          _adbInstallIncompatible);

      final result = await runTarget(
        DeviceTarget(waitSeconds: 0, adbPath: incompatible),
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('adb install failed'));
    });

    test('crash signature in the device log fails the smoke test', () async {
      final apk = File(
        p.join(project.path, '.oka_cache', 'build', 'debug', 'app-debug.apk'),
      );
      await apk.parent.create(recursive: true);
      await apk.writeAsBytes(List.filled(8, 4));
      final crashing = await _fakeTool(tools, 'adb3', _adbCrashLog);

      final result = await runTarget(
        DeviceTarget(waitSeconds: 0, adbPath: crashing, aapt2Path: aapt2),
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('failure signatures'));
      expect(result.error, contains('fatal-exception'));
    });

    test('a dead process after launch fails the smoke test', () async {
      final apk = File(
        p.join(project.path, '.oka_cache', 'build', 'debug', 'app-debug.apk'),
      );
      await apk.parent.create(recursive: true);
      await apk.writeAsBytes(List.filled(8, 5));
      final dying = await _fakeTool(tools, 'adb4', _adbDeadProcess);

      final result = await runTarget(
        DeviceTarget(waitSeconds: 0, adbPath: dying, aapt2Path: aapt2),
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('process died after launch'));
    });

    test('noInstall skips install entirely (install failure never seen)',
        () async {
      final apk = File(
        p.join(project.path, '.oka_cache', 'build', 'debug', 'app-debug.apk'),
      );
      await apk.parent.create(recursive: true);
      await apk.writeAsBytes(List.filled(8, 6));
      // Even if install would fail, the step is not compiled — the launch
      // path must run cleanly without it.
      final result = await runTarget(
        DeviceTarget(
          noInstall: true,
          waitSeconds: 0,
          package: 'com.example.app',
          activity: 'com.example.app.MainActivity',
          adbPath: adb,
        ),
      );
      expect(result.ok, isTrue, reason: result.error);
    });

    test('missing package name (no badging, no override) fails with the '
        'target-config hint', () async {
      final apk = File(
        p.join(project.path, '.oka_cache', 'build', 'debug', 'app-debug.apk'),
      );
      await apk.parent.create(recursive: true);
      await apk.writeAsBytes(List.filled(8, 7));
      final silentAapt2 = await _fakeTool(tools, 'aapt2_silent', 'exit 1');

      final result = await runTarget(
        DeviceTarget(waitSeconds: 0, adbPath: adb, aapt2Path: silentAapt2),
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('Could not determine package name'));
      expect(result.error, contains('DeviceTarget(package:'));
    });
  });

  group('pure helpers', () {
    test('parseAapt2Badging extracts package and launchable-activity', () {
      final badging = parseAapt2Badging(
        "package: name='dev.a.b' versionCode='3' versionName='1.2.3'\n"
        "sdkVersion:'21'\n"
        "launchable-activity: name='dev.a.b.MainActivity'  label='App'\n",
      );
      expect(badging['package'], 'dev.a.b');
      expect(badging['launchable-activity'], 'dev.a.b.MainActivity');
    });

    test('parseAapt2Badging tolerates missing sections', () {
      expect(parseAapt2Badging('nothing useful\n'), isEmpty);
    });

    test('scanLogForFailureSignatures finds each signature (case-insensitive)',
        () {
      const log = 'I/chatty: ok\n'
          'E/AndroidRuntime: FATAL EXCEPTION: main\n'
          'W/System: Unable to establish connection on channel\n';
      final found = scanLogForFailureSignatures(log);
      expect(found.keys, containsAll(['fatal-exception',
          'pigeon-channel-missing']));
      expect(found, hasLength(2));
    });

    test('scanLogForFailureSignatures returns empty for a clean log', () {
      expect(scanLogForFailureSignatures('all good\n'), isEmpty);
    });

    test('findNewestBuiltApk picks the newest across mode dirs (incl. aab)',
        () async {
      final project = await Directory.systemTemp
          .createTemp('oka_device_newest_');
      addTearDown(() => project.delete(recursive: true));
      final debug = File(
        p.join(project.path, '.oka_cache', 'build', 'debug', 'app-debug.apk'),
      );
      final release = File(
        p.join(
          project.path,
          '.oka_cache',
          'build',
          'release',
          'aab',
          'app-release.aab.apk',
        ),
      );
      debug.parent.createSync(recursive: true);
      release.parent.createSync(recursive: true);
      debug.writeAsStringSync('debug');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      release.writeAsStringSync('release');

      expect(await findNewestBuiltApk(project.path), release.path);
      expect(
        await findNewestBuiltApk(
          Directory.systemTemp.createTempSync('oka_empty_').path,
        ),
        isNull,
      );
    });
  });
}
