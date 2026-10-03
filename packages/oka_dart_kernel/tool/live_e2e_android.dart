/// Live-e2e android leg as a Dart driver (ADR-0036 Tier 1): emulator
/// bring-up (or reuse), the app's known-good build fixes applied and
/// reverted, `flutter run` + DevFS push + `_reloadKernel` — the
/// standalone "live-patch a flutter android app" flow. Proves: probe
/// flip + hold (no restart) + receipt ok.
///
/// Env: LIVE_APP_ROOT (last_answer), FLUTTER_BIN, ANDROID_EMULATOR, ADB,
/// ANDROID_SDK_ROOT, OKA_SDK_CHECKOUT_FLUTTER. Exit 0 = leg PASS.
library;

import 'dart:convert';
import 'dart:io';

import 'package:oka_update/oka_update.dart';

import 'flutter_delta.dart';

// ignore_for_file: avoid_print, unused_local_variable, unnecessary_raw_strings, prefer_const_constructors

final home = Platform.environment['HOME']!;
final appRoot = Platform.environment['LIVE_APP_ROOT'] ??
    '$home/xs/storage_problem/last_answer';
final flutterBin = Platform.environment['FLUTTER_BIN'] ??
    '$home/fvm/default/bin/flutter';
final emulatorBin = Platform.environment['ANDROID_EMULATOR'] ??
    '$home/.oka/android-sdk/emulator/emulator';
final adbBin =
    Platform.environment['ADB'] ?? '$home/.oka/android-sdk/platform-tools/adb';
final androidSdk = Platform.environment['ANDROID_SDK_ROOT'] ??
    Platform.environment['ANDROID_HOME'] ??
    '$home/.oka/android-sdk';

/// flutter discovers android devices only when the SDK env is set (the
/// shell gate exported these; the driver must too).
Map<String, String> flutterEnv() => {
      ...Platform.environment,
      'ANDROID_SDK_ROOT': androidSdk,
      'ANDROID_HOME': androidSdk,
    };

const unitFile = 'packages/headless_core/lib/src/fractional_order.dart';
final toolDir = File.fromUri(Platform.script).parent.path;
final repoRoot = File.fromUri(Platform.script).parent.parent.path;
final backupDir = '$appRoot/.oka_live_android_backup';

Future<void> main() async {
  await restoreMarkers();
  await patchBuild();
  final emulator = await ensureEmulator();
  Process? flutterRun;
  var failed = false;
  final log = <String>[];
  try {
    final devices = await Process.run(adbBin, ['devices']);
    final devLine = (devices.stdout as String)
        .split('\n')
        .firstWhere((l) => l.contains('emulator-') && l.contains('device'),
            orElse: () => '');
    if (devLine.isEmpty) throw StateError('no emulator device');
    final dev = devLine.split('\t').first;

    // adb seeing the device is not enough — wait until flutter's own
    // discovery lists it (classic daemon race).
    final sw2 = Stopwatch()..start();
    while (true) {
      final fd = await Process.run(
          flutterBin, ['devices', '--machine', '--suppress-analytics'],
          environment: flutterEnv());
      if ((fd.stdout as String).contains('"id": "$dev"') ||
          (fd.stdout as String).contains('"id":"$dev"')) {
        break;
      }
      if (sw2.elapsed > const Duration(seconds: 90)) {
        throw StateError('flutter never discovered $dev');
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }

    flutterRun = await Process.start(flutterBin, [
      'run',
      '-d',
      dev,
      '--debug',
      '--android-skip-build-dependency-validation',
    ],
        workingDirectory: appRoot,
        environment: flutterEnv());
    flutterRun.stdout.transform(const Utf8Decoder()).listen(log.add);
    flutterRun.stderr.transform(const Utf8Decoder()).listen(log.add);
    await waitLine(
        log, 'A Dart VM Service', const Duration(minutes: 12), 'vm service');
    final uriLine = log.firstWhere((l) => l.contains('A Dart VM Service'));
    final httpBase =
        RegExp(r'http://[^ \r\n]+').firstMatch(uriLine)!.group(0)!.trim();
    final ws =
        '${httpBase.replaceFirst('http', 'ws').replaceAll(RegExp(r'/+$'), '')}/ws';
    print('android: VM service at $ws');

    // The app's own frontend: checkout-frontend deltas crash the app's
    // VM on the reload path (same wire fact as desktop).
    final (dartSdk, frontend, patchedSdk) = flutterToolchainPaths(flutterBin);
    final compile = flutterFrontendDeltaCompiler(
        frontend, dartSdk, patchedSdk, '$appRoot/.dart_tool/package_config.json');

    final receipt = await runLivePatch(
      LivePatchSpec(
        revision: 'rev-b',
        unit: 'fractional_order',
        patches: [
          PatchEdit(
            file: unitFile,
            find: "const String _alphabet = 'abcdefghijklmnopqrstuvwxyz';",
            replace: "const String _alphabet = 'acbdefghijklmnopqrstuvwxyz';",
          ),
        ],
        targets: [
          TargetSpec(
            kind: 'vm',
            id: 'android-emulator',
            ws: ws,
            http: httpBase,
            devfs: 'oka_live',
          ),
        ],
        probes: const [
          ProbeSpec(
            library: 'fractional_order.dart',
            expression: "fractionalBetween('a', null)",
            expect: 'c',
          ),
          ProbeSpec(
            library: 'lastanswer/main.dart',
            expression: 'identityHashCode(main)',
            hold: true,
          ),
        ],
      ),
      compile: compile,
      root: appRoot,
      onEvent: (e) => print('live: ${e.why}'),
    );
    print(receipt.describe());
    if (!receipt.ok) throw StateError('live patch refused');
    print('android: live patch OK');
  } catch (e) {
    failed = true;
    print('android: FAILED — $e');
    final s = log.join('\n');
    print(s.length > 2000 ? s.substring(s.length - 2000) : s);
  } finally {
    flutterRun?.kill();
    await restoreBuild();
    await restoreMarkers();
    // The emulator stays up (the gate reuses it across runs).
  }
  exit(failed ? 1 : 0);
}

Future<void> waitLine(
    List<String> lines, String pattern, Duration timeout, String what) async {
  final sw = Stopwatch()..start();
  while (!lines.join('\n').contains(pattern)) {
    if (sw.elapsed > timeout) {
      throw StateError('timeout waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

/// Boots `oka-emulator` when no emulator device is up.
Future<bool> ensureEmulator() async {
  final probe = await Process.run(adbBin, ['devices']);
  if ((probe.stdout as String).contains('emulator-')) {
    final boot = await Process.run(adbBin, ['shell', 'getprop', 'sys.boot_completed']);
    if ((boot.stdout as String).trim() == '1') return true;
  }
  print('android: booting emulator (oka-emulator)…');
  final emu = await Process.start(emulatorBin,
      ['-avd', 'oka-emulator', '-no-snapshot', '-no-audio', '-no-boot-anim']);
  for (var i = 0; i < 30; i++) {
    final boot =
        await Process.run(adbBin, ['shell', 'getprop', 'sys.boot_completed']);
    if ((boot.stdout as String).trim() == '1') {
      print('android: emulator booted');
      return true;
    }
    await Future<void>.delayed(const Duration(seconds: 10));
  }
  emu.kill();
  return false;
}

/// The app's committed android config cannot build under this flutter
/// (wrapper/AGP below the floor; debug signing points at a protected
/// keystore). Apply the two known-good fixes; [restoreBuild] reverts.
Future<void> patchBuild() async {
  Directory(backupDir).createSync(recursive: true);
  for (final f in [
    'android/gradle/wrapper/gradle-wrapper.properties',
    'android/settings.gradle.kts',
    'android/app/build.gradle.kts',
  ]) {
    File('$appRoot/$f').copySync('$backupDir/${f.split('/').last}');
  }
  await Process.run('sed', ['-i', '', 's/gradle-8.12-all.zip/gradle-8.14-all.zip/',
      '$appRoot/android/gradle/wrapper/gradle-wrapper.properties']);
  await Process.run('sed', ['-i', '',
      's/id("com.android.application") version "8.7.3" apply false/id("com.android.application") version "8.11.1" apply false/',
      '$appRoot/android/settings.gradle.kts']);
  final patch = await Process.run('dart', [
    '$toolDir/live_e2e_spec.dart',
    'patch-android-signing',
    appRoot,
  ], workingDirectory: repoRoot);
  if (patch.exitCode != 0) {
    throw StateError('signing patch failed: ${patch.stderr}');
  }
}

Future<void> restoreBuild() async {
  if (!Directory(backupDir).existsSync()) return;
  for (final f in [
    'android/gradle/wrapper/gradle-wrapper.properties',
    'android/settings.gradle.kts',
    'android/app/build.gradle.kts',
  ]) {
    final b = File('$backupDir/${f.split('/').last}');
    if (b.existsSync()) b.copySync('$appRoot/$f');
  }
  Directory(backupDir).deleteSync(recursive: true);
}

Future<void> restoreMarkers() async {
  final f = File('$appRoot/$unitFile');
  if (!f.existsSync()) return;
  await f.writeAsString((await f.readAsString())
      .replaceAll('acbdefghijklmnopqrstuvwxyz', 'abcdefghijklmnopqrstuvwxyz'));
}
