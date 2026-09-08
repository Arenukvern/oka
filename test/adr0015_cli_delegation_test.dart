// ADR-0015 follow-up — unit tests for the oka_android APIs the CLI verbs now
// delegate to (all mocked: no real SDK, no network, no bundletool needed).
//
// Covered:
//  - `androidSdkDoctorChecks` (oka doctor's Android SDK section, results as
//    data) with an injected fake toolchain;
//  - `bundletoolAvailableInOkaTools` / `bundletoolHealthLines` (oka doctor's
//    Build-Health lines) with an injected tools dir;
//  - `verifyAabPostBuild` (oka build --verify-aab loop) with injected
//    verifier + keystore;
//  - `compareArtifacts(skipBadgingSection: …)` — the `oka compare
//    --skip-badging` routing resolves inside oka_android now;
//  - `okaGetUsageText` / `androidProvisioners` — the `oka get` noun registry.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Fake toolchain: canned answers, no environment probing.
class _FakeToolchain extends ResolvedToolchain {
  _FakeToolchain({this.missingSdk = false})
      : super(androidSdkPath: '/fake/sdk');
  final bool missingSdk;

  @override
  Future<String> findAndroidSdk() async {
    if (missingSdk) throw Exception('no sdk');
    return '/fake/sdk';
  }

  @override
  Future<String> findAapt2() async => '/fake/sdk/build-tools/35.0.0/aapt2';

  @override
  Future<String> findD8() async => throw Exception('d8 missing');

  @override
  Future<String> findZipalign() async => '/fake/sdk/build-tools/35.0.0/zipalign';

  @override
  Future<String> findApksigner() async =>
      '/fake/sdk/build-tools/35.0.0/apksigner';

  @override
  Future<String> findAdb() async => '/fake/sdk/platform-tools/adb';

  @override
  Future<String?> findR8() async => null;
}

void main() {
  group('androidSdkDoctorChecks', () {
    test('returns ordered tool checks as data when the SDK is found', () async {
      final report = await androidSdkDoctorChecks(toolchain: _FakeToolchain());
      expect(report.sdkFound, isTrue);
      expect(report.sdkPath, '/fake/sdk');
      expect(report.sdkError, isNull);
      expect(
        report.toolChecks.map((c) => c.tool),
        ['aapt2', 'd8', 'zipalign', 'apksigner', 'adb'],
      );
      expect(report.toolChecks.where((c) => c.found).length, 4);
      final d8 = report.toolChecks.firstWhere((c) => c.tool == 'd8');
      expect(d8.found, isFalse);
      expect(d8.path, isNull);
      expect(d8.error, isNotNull);
      // R8 optional: absent → null (doctor prints its warning).
      expect(report.r8Path, isNull);
    });

    test('returns no tool checks when the SDK root is missing', () async {
      final report =
          await androidSdkDoctorChecks(toolchain: _FakeToolchain(missingSdk: true));
      expect(report.sdkFound, isFalse);
      expect(report.sdkPath, isNull);
      expect(report.sdkError, isNotNull);
      expect(report.toolChecks, isEmpty);
      expect(report.r8Path, isNull);
    });
  });

  group('bundletool health checks', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('oka-doctor-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('detects a bundletool jar in the oka tools dir', () async {
      File(p.join(tmp.path, 'bundletool-all-1.17.0.jar'))
          .writeAsStringSync('jar');
      expect(await bundletoolAvailableInOkaTools(toolsDir: tmp), isTrue);
    });

    test('absent or unrelated tools dir reports not installed', () async {
      expect(await bundletoolAvailableInOkaTools(toolsDir: tmp), isFalse);
      File(p.join(tmp.path, 'other-tool.jar')).writeAsStringSync('x');
      expect(await bundletoolAvailableInOkaTools(toolsDir: tmp), isFalse);
    });

    test('health lines are byte-identical to the doctor output', () async {
      const missingLine =
          '  ℹ️  bundletool not installed (only needed for --verify-aab) —'
          ' "oka get bundletool"';
      expect(
        await bundletoolHealthLines(toolsDir: tmp),
        [missingLine],
      );
      File(p.join(tmp.path, 'bundletool.jar')).writeAsStringSync('jar');
      expect(
        await bundletoolHealthLines(toolsDir: tmp),
        ['  ✅ bundletool: available for AAB verification'],
      );
    });
  });

  group('verifyAabPostBuild', () {
    late Directory tmp;
    late String aabPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('oka-verify-aab-');
      aabPath = p.join(tmp.path, 'app.aab');
      File(aabPath).writeAsStringSync('aab-bytes');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<BundletoolVerifyResult> okStub({
      required String aabPath,
      required String outputApksPath,
      required String keystorePath,
      required String keyAlias,
      required String keyPass,
      String? bundletoolPath,
      bool verbose = false,
    }) async =>
        BundletoolVerifyResult(ok: true, apksPath: outputApksPath);

    test('extracts the universal APK and returns true on success', () async {
      final apksPath = '${p.withoutExtension(aabPath)}.apks';
      final archive = Archive()
        ..addFile(ArchiveFile('toc.pb', 2, [1, 1]))
        ..addFile(ArchiveFile('splits/universal.apk', 4, [9, 9, 9, 9]));
      File(apksPath).writeAsBytesSync(ZipEncoder().encodeBytes(archive));

      final ok = await verifyAabPostBuild(
        aabPath,
        verbose: false,
        verify: okStub,
        keystore: () async => '/fake/debug.keystore',
      );

      expect(ok, isTrue);
      final universal = File(
        p.join(p.dirname(aabPath), 'universal', 'app-universal.apk'),
      );
      expect(universal.existsSync(), isTrue);
      expect(universal.lengthSync(), 4);
    });

    test('returns false when verification fails', () async {
      final ok = await verifyAabPostBuild(
        aabPath,
        verbose: false,
        verify: ({
          required aabPath,
          required outputApksPath,
          required keystorePath,
          required keyAlias,
          required keyPass,
          bundletoolPath,
          verbose = false,
        }) async =>
            BundletoolVerifyResult(
              ok: false,
              apksPath: outputApksPath,
              error: 'build-apks exploded',
            ),
        keystore: () async => '/fake/debug.keystore',
      );

      expect(ok, isFalse);
    });
  });

  group('compareArtifacts skip routing', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('oka-compare-'));
    tearDown(() => tmp.deleteSync(recursive: true));

    File writeZip(String path, Map<String, List<int>> entries) {
      final archive = Archive();
      for (final e in entries.entries) {
        archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
      }
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(ZipEncoder().encodeBytes(archive));
      return file;
    }

    test('skipBadgingSection forces the historical skip reason', () async {
      final a = writeZip(p.join(tmp.path, 'a.apk'), {
        'classes.dex': [1],
      });
      final b = writeZip(p.join(tmp.path, 'b.apk'), {
        'classes.dex': [2],
      });
      final cmp = await compareArtifacts(a.path, b.path, skipBadgingSection: true);
      expect(
        cmp.badgingSkippedReason,
        'no aapt2 found (set ANDROID_SDK_ROOT or run `oka get android-sdk`) '
        '— zip entries still compared',
      );
      expect(cmp.badgingA, isNull);
      // The zip diff still applies.
      expect(cmp.zipDiff.changedContent, ['classes.dex']);
      expect(cmp.hasDifferences, isTrue);
    });

    test('explicit aapt2 path is used without resolution', () async {
      final a = writeZip(p.join(tmp.path, 'a.apk'), {
        'classes.dex': [1],
      });
      final cmp = await compareArtifacts(
        a.path,
        a.path,
        aapt2Path: '/definitely/not/a/aapt2',
      );
      // The injected (non-existent) binary fails → captured as skip reason.
      expect(cmp.badgingSkippedReason, isNotNull);
      expect(cmp.badgingA, isNull);
      expect(cmp.zipDiff.isEmpty, isTrue);
    });
  });

  group('oka get provisioner registry', () {
    test('registers the Android nouns with oka_android implementations', () {
      expect(
        androidProvisioners.keys.toList()..sort(),
        ['build-tools', 'bundletool', 'kotlin', 'r8'],
      );
    });

    test('usage text documents the provisioning nouns', () {
      expect(okaGetUsageText, startsWith('Usage: oka get <dependency>'));
      for (final noun in [
        'android-sdk',
        'packaging-sdk',
        'r8',
        'build-tools',
        'kotlin',
        'java <version>',
        'all',
      ]) {
        expect(okaGetUsageText, contains(noun));
      }
      expect(okaGetUsageText, endsWith('Run "oka doctor" to see what\'s currently installed.\n'));
    });
  });
}
