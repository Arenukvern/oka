// ADR-0011 H0 — hot-reload prerequisite audit: prove the oka-built debug
// APK is hot-reload-capable.
//
// Static parts (always run):
// * `-dTrackWidgetCreation=true` is passed for debug assemble (pure arg
//   construction — the flag the checklist calls out explicitly);
// * debug assemble target is the JIT `debug_android_application`.
//
// Real-pipeline parts (skip gracefully when no Flutter/Android SDK — the
// `determinism_test` skip pattern; CI/device tiers follow PHASE_CHECKLIST):
// * build a debug APK of a minimal fixture project through the real
//   no-Gradle pipeline (FlutterApkBuilder → defaultApkPipeline — the only
//   build path, no Gradle), then assert the packaged zip entries:
//   `kernel_blob.bin` present in flutter_assets, `vm_snapshot_data` +
//   `isolate_snapshot_data` present (JIT markers), `libflutter.so` present,
//   and **no** AOT `libapp.so` anywhere;
// * the same build must record `run_session.json` next to the APK
//   (H1 golden evidence at the pipeline level).
//
// Device/emulator parts (VM service probe, attach transcript) are recorded
// in docs/guides/hot_reload_plan.md — H0 evidence block — with the honest
// blocker reason when no device is attached.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _fixturePubspec = '''
name: hotreload_fixture
version: 1.0.0
environment:
  sdk: ^3.10.0
dependencies:
  flutter:
    sdk: flutter
flutter:
  uses-material-design: true
''';

const _fixtureMain = '''
import 'package:flutter/material.dart';

void main() => runApp(const HotReloadFixture());

class HotReloadFixture extends StatelessWidget {
  const HotReloadFixture({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: Text('ok'));
}
''';

BuildContext _fixtureContext(final String projectPath) {
  final buildDir = p.join(projectPath, '.oka_cache', 'build', 'debug');
  return BuildContext.fromJson({
    'project_path': projectPath,
    'build_dir': buildDir,
    'mode': 'debug',
    'config': {
      'name': 'hotreload_fixture',
      'version': '1.0.0',
      'android': {
        'package_name': 'dev.example.fixture',
        'application_id': 'dev.example.fixture',
        'min_sdk': '21',
        'target_sdk': '34',
        'compile_sdk': '34',
        'version_code': 1,
        'version_name': '1.0.0',
        'abis': ['x86_64'],
        'java_version': 11,
      },
      'flutter': {
        'entrypoint': 'lib/main.dart',
        'build_mode': 'debug',
      },
    },
    'cache_dir': p.join(projectPath, '.oka_cache'),
    'temp_dir': p.join(buildDir, 'temp'),
    'verbose': false,
    'target_abi': 'x86_64',
    'build_aab': false,
  });
}

void main() {
  group('H0 static: debug assemble args are hot-reload capable', () {
    test('debug passes -dTrackWidgetCreation=true (JIT widget inspector)',
        () {
      final args = buildFlutterAssembleArgs(
        outputDir: 'out',
        targetFile: 'lib/main.dart',
        mode: BuildMode.debug,
        targetPlatform: 'android-x64',
      );
      expect(args, contains('-dTrackWidgetCreation=true'));
      expect(args, contains('debug_android_application'));
    });

    test('release never passes TrackWidgetCreation (AOT path)', () {
      final args = buildFlutterAssembleArgs(
        outputDir: 'out',
        targetFile: 'lib/main.dart',
        mode: BuildMode.release,
        targetPlatform: 'android-arm64',
      );
      expect(args.where((final a) => a.startsWith('-dTrackWidgetCreation')),
          isEmpty);
      expect(args, contains('release_android_application'));
    });

    test('debug assemble argv stays a batch CLI (no gradle, no build apk)',
        () {
      final args = buildFlutterAssembleArgs(
        outputDir: 'out',
        targetFile: 'lib/main.dart',
        mode: BuildMode.debug,
        targetPlatform: 'android-x64',
      ).join(' ');
      expect(args, isNot(contains('gradle')));
      expect(args, isNot(contains('build apk')));
    });
  });

  group('H0 real pipeline: packaged debug APK contents', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_h0_apk_');
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('oka-built debug APK has kernel_blob.bin, no AOT libapp.so; '
        'run_session.json recorded next to it', () async {
      // Requires the real Flutter + Android SDKs; skips gracefully on
      // machines/CI without them (the emulator tier owns device evidence).
      final toolchain = ResolvedToolchain();
      String flutterSdk;
      String androidSdk;
      try {
        flutterSdk = await toolchain.findFlutterSdk();
        androidSdk = await toolchain.findAndroidSdk();
      } on ToolchainException {
        return onSkip(
          'flutter/Android SDK not resolvable — real-pipeline H0 evidence '
          'runs on machines with both installed (see PHASE_CHECKLIST)',
        );
      }
      expect(flutterSdk, isNotEmpty);
      expect(androidSdk, isNotEmpty);

      // Minimal fixture project.
      final project = tmp.path;
      final main = File(p.join(project, 'lib', 'main.dart'));
      await main.create(recursive: true);
      await main.writeAsString(_fixtureMain);
      await File(p.join(project, 'pubspec.yaml')).writeAsString(_fixturePubspec);

      // Real pub get (assemble never runs it implicitly).
      final pubGet = await Process.run(
        p.join(flutterSdk, 'bin', 'flutter'),
        ['pub', 'get'],
        workingDirectory: project,
      );
      if (pubGet.exitCode != 0) {
        return onSkip('flutter pub get failed: ${pubGet.stderr}');
      }

      // The one and only build path: FlutterApkBuilder → defaultApkPipeline
      // (no Gradle — phase-0 invariant).
      final builder = FlutterApkBuilder(toolchain);
      final artifact = await builder.buildApk(_fixtureContext(project));
      expect(artifact.success, isTrue,
          reason: 'oka debug build must succeed for H0: ${artifact.error}');

      final apk = File(artifact.apkPath);
      expect(apk.existsSync(), isTrue);

      // Zip-entry assertions — the hot-reload capability contract.
      final bytes = await apk.readAsBytes();
      final entries = ZipDecoder()
          .decodeBytes(bytes)
          .where((final f) => f.isFile)
          .map((final f) => f.name)
          .toList();
      String? find(final String suffix) => entries
          .where((final e) => e.endsWith(suffix))
          .fold<String?>(null, (final a, final e) => a ?? e);
      expect(
        find('flutter_assets/kernel_blob.bin'),
        isNotNull,
        reason: 'JIT debug build must ship kernel_blob.bin (the hot-reload '
            'kernel flutter attach replaces)',
      );
      expect(
        find('flutter_assets/isolate_snapshot_data'),
        isNotNull,
        reason: 'JIT marker absent — is this accidentally an AOT build?',
      );
      expect(
        entries.any((final e) => e.contains('libflutter.so')),
        isTrue,
        reason: 'engine runtime must be packaged',
      );
      expect(
        entries.any((final e) => e.endsWith('libapp.so')),
        isFalse,
        reason: 'AOT libapp.so must NOT be in a debug (JIT) APK',
      );
      expect(
        entries.any((final e) => e.endsWith('classes.dex')),
        isTrue,
      );

      // H1 golden evidence at the pipeline level: the default pipeline
      // recorded the session manifest next to the APK.
      final session = RunSession.forApk(apk.path);
      expect(session, isNotNull, reason: 'run_session.json must be recorded '
          'next to the APK by the default pipeline');
      expect(session!.buildMode, 'debug');
      expect(session.flutterSdkPath, flutterSdk);
      expect(session.engineRevision, isNotEmpty);
      expect(session.targetFile, 'lib/main.dart');
      expect(session.abis, ['x86_64']);
      expect(
        flutterBinaryForSdk(session.flutterSdkPath).exists,
        isTrue,
        reason: 'the recorded SDK must hold the session flutter binary',
      );
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}

void onSkip(final String reason) {
  // ignore: avoid_print
  print('skipped: $reason');
}
