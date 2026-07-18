import 'dart:io';

import 'package:oka/src/build/apk_layout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('incomplete layout must not be treated as success', () {
    test('validatePathSet fails without classes.dex', () {
      final v = validatePathSet(
        [
          'assets/flutter_assets/kernel_blob.bin',
          'lib/arm64-v8a/libflutter.so',
        ],
        spec: const ApkLayoutSpec(abis: ['arm64-v8a']),
      );
      expect(v.ok, isFalse);
      expect(v.missing, contains('classes.dex'));
    });

    test('validatePathSet fails without libflutter.so', () {
      final v = validatePathSet(
        [
          'classes.dex',
          'assets/flutter_assets/AssetManifest.json',
        ],
        spec: const ApkLayoutSpec(abis: ['arm64-v8a']),
      );
      expect(v.ok, isFalse);
      expect(v.missing, contains('lib/arm64-v8a/libflutter.so'));
    });

    test('builder throws on incomplete layout (source contract)', () async {
      final text = await File(
        p.join('lib', 'src', 'build', 'flutter_apk_builder.dart'),
      ).readAsString();
      // Must throw / fail — not only warn
      expect(text, contains('APK layout incomplete'));
      expect(text, isNot(contains('⚠️  APK layout incomplete')));
      // success:true only after validation ok path
      expect(
        text.contains('if (!validation.ok)') &&
            text.contains('throw Exception'),
        isTrue,
      );
    });

    test('zip of incomplete staging fails validation', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_layout_fail_');
      addTearDown(() async {
        if (await tmp.exists()) {
          await tmp.delete(recursive: true);
        }
      });

      final staging = p.join(tmp.path, 'staging');
      await Directory(p.join(staging, 'assets', 'flutter_assets'))
          .create(recursive: true);
      await File(p.join(staging, 'assets', 'flutter_assets', 'x'))
          .writeAsString('y');
      // missing dex and libflutter

      final apk = p.join(tmp.path, 'bad.apk');
      await zipStagingToApk(staging, apk);
      final entries = await listApkEntries(apk);
      final v = validatePathSet(
        entries,
        spec: const ApkLayoutSpec(abis: ['arm64-v8a']),
      );
      expect(v.ok, isFalse);
      expect(v.missing, isNotEmpty);
    });
  });
}
