import 'dart:io';

import 'package:oka_android/src/build/apk_layout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('normalizeAbi / resolveAbis', () {
    test('normalizes flutter platform names', () {
      expect(normalizeAbi('android-arm64'), 'arm64-v8a');
      expect(normalizeAbi('android-arm'), 'armeabi-v7a');
      expect(normalizeAbi('android-x64'), 'x86_64');
    });

    test('resolveAbis prefers targetAbi', () {
      expect(
        resolveAbis(configAbis: ['armeabi-v7a', 'x86'], targetAbi: 'arm64-v8a'),
        ['arm64-v8a'],
      );
    });

    test('resolveAbis defaults to arm64-v8a', () {
      expect(resolveAbis(configAbis: []), ['arm64-v8a']);
    });

    test('resolveAbis dedupes config list', () {
      expect(
        resolveAbis(configAbis: ['arm64-v8a', 'android-arm64', 'armeabi-v7a']),
        ['arm64-v8a', 'armeabi-v7a'],
      );
    });
  });

  group('engineArtifactDirForAbi', () {
    test('maps abis to flutter engine dirs', () {
      expect(
        engineArtifactDirForAbi('arm64-v8a', release: false),
        'android-arm64',
      );
      expect(
        engineArtifactDirForAbi('arm64-v8a', release: true),
        'android-arm64-release',
      );
      expect(
        engineArtifactDirForAbi('armeabi-v7a', release: false),
        'android-arm',
      );
    });
  });

  group('stageApkLayout + validate', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_apk_layout_');
    });

    tearDown(() async {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    });

    test('stages dex, flutter_assets, libflutter.so and validates', () async {
      final assets = Directory(p.join(tmp.path, 'src_assets'));
      await assets.create(recursive: true);
      await File(p.join(assets.path, 'AssetManifest.json'))
          .writeAsString('{}');
      await File(p.join(assets.path, 'kernel_blob.bin'))
          .writeAsBytes([1, 2, 3]);

      final so = File(p.join(tmp.path, 'libflutter.so'));
      await so.writeAsBytes([0x7f, 0x45, 0x4c, 0x46]); // ELF magic-ish

      final dex = File(p.join(tmp.path, 'classes.dex'));
      await dex.writeAsBytes([0x64, 0x65, 0x78, 0x0a, 0x30, 0x33, 0x35, 0x00]);

      final staging = p.join(tmp.path, 'staging');
      await stageApkLayout(
        stagingDir: staging,
        dexFile: dex.path,
        flutterAssetsDir: assets.path,
        libflutterByAbi: {'arm64-v8a': so.path},
      );

      final validation = await validateStagingLayout(
        staging,
      );
      expect(validation.ok, isTrue, reason: 'missing: ${validation.missing}');
      expect(validation.present, contains('classes.dex'));
      expect(validation.present, contains('assets/flutter_assets/'));
      expect(validation.present, contains('lib/arm64-v8a/libflutter.so'));

      final apkPath = p.join(tmp.path, 'app.apk');
      await zipStagingToApk(staging, apkPath);
      expect(await File(apkPath).exists(), isTrue);

      final entries = await listApkEntries(apkPath);
      final zipValidation = validatePathSet(
        entries,
      );
      expect(zipValidation.ok, isTrue, reason: 'missing: ${zipValidation.missing}');
    });

    test('requireLibapp fails when libapp.so missing', () async {
      final staging = p.join(tmp.path, 'staging2');
      await Directory(p.join(staging, 'assets', 'flutter_assets'))
          .create(recursive: true);
      await File(p.join(staging, 'classes.dex')).writeAsBytes([1]);
      await File(p.join(staging, 'lib', 'arm64-v8a', 'libflutter.so'))
          .create(recursive: true);

      final v = await validateStagingLayout(
        staging,
        spec: const ApkLayoutSpec(
          requireLibapp: true,
        ),
      );
      expect(v.ok, isFalse);
      expect(v.missing, contains('lib/arm64-v8a/libapp.so'));
    });

    test('multi-abi staging includes both libflutter.so paths', () async {
      final so = File(p.join(tmp.path, 'libflutter.so'));
      await so.writeAsBytes([1, 2, 3]);
      final assets = Directory(p.join(tmp.path, 'fa'));
      await assets.create();
      await File(p.join(assets.path, 'x')).writeAsString('y');
      final dex = File(p.join(tmp.path, 'd.dex'));
      await dex.writeAsBytes([9]);

      final staging = p.join(tmp.path, 'multi');
      await stageApkLayout(
        stagingDir: staging,
        dexFile: dex.path,
        flutterAssetsDir: assets.path,
        libflutterByAbi: {
          'arm64-v8a': so.path,
          'armeabi-v7a': so.path,
        },
        libappByAbi: {
          'arm64-v8a': so.path,
          'armeabi-v7a': so.path,
        },
      );

      final v = await validateStagingLayout(
        staging,
        spec: const ApkLayoutSpec(
          abis: ['arm64-v8a', 'armeabi-v7a'],
          requireLibapp: true,
        ),
      );
      expect(v.ok, isTrue, reason: '${v.missing}');
    });
  });
}
