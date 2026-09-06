import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/src/build/aab_layout.dart';
import 'package:oka_android/src/build/aapt2_commands.dart';
import 'package:test/test.dart';

void main() {
  group('buildAapt2LinkProtoFormatArgs', () {
    test('uses --proto-format and single -R compiled zip', () {
      final args = buildAapt2LinkProtoFormatArgs(
        androidJar: '/sdk/platforms/android-34/android.jar',
        manifestPath: '/build/AndroidManifest.xml',
        outputAp: '/build/resources_proto.ap_',
        compiledResourcesZip: '/build/compiled_resources.zip',
        javaOutDir: '/build/gen',
      );
      expect(args.first, 'link');
      expect(args, contains('--proto-format'));
      expect(
        args[args.indexOf('-I') + 1],
        '/sdk/platforms/android-34/android.jar',
      );
      expect(args[args.indexOf('-o') + 1], '/build/resources_proto.ap_');
      expect(args[args.indexOf('-R') + 1], '/build/compiled_resources.zip');
    });
  });

  group('validateAabPathSet', () {
    test('complete debug bundle passes', () {
      final v = validateAabPathSet([
        'BundleConfig.pb',
        'base/manifest/AndroidManifest.xml',
        'base/resources.pb',
        'base/dex/classes.dex',
        'base/assets/flutter_assets/AssetManifest.json',
        'base/lib/arm64-v8a/libflutter.so',
      ]);
      expect(v.ok, isTrue);
    });

    test('manifest at APK-style path fails (must be base/manifest/)', () {
      final v = validateAabPathSet([
        'BundleConfig.pb',
        'base/AndroidManifest.xml', // wrong location
        'base/resources.pb',
        'base/dex/classes.dex',
        'base/assets/flutter_assets/x',
        'base/lib/arm64-v8a/libflutter.so',
      ]);
      expect(v.ok, isFalse);
      expect(v.missing, contains('base/manifest/AndroidManifest.xml'));
    });

    test('missing BundleConfig.pb fails', () {
      final v = validateAabPathSet([
        'base/manifest/AndroidManifest.xml',
        'base/resources.pb',
        'base/dex/classes.dex',
        'base/assets/flutter_assets/x',
        'base/lib/arm64-v8a/libflutter.so',
      ]);
      expect(v.ok, isFalse);
      expect(v.missing, contains('BundleConfig.pb'));
    });

    test('release requires libapp.so per ABI', () {
      final entries = [
        'BundleConfig.pb',
        'base/manifest/AndroidManifest.xml',
        'base/resources.pb',
        'base/dex/classes.dex',
        'base/assets/flutter_assets/x',
        'base/lib/arm64-v8a/libflutter.so',
      ];
      final release = validateAabPathSet(
        entries,
        spec: const AabLayoutSpec(abis: ['arm64-v8a'], requireLibapp: true),
      );
      expect(release.ok, isFalse);
      expect(release.missing, contains('base/lib/arm64-v8a/libapp.so'));

      final withLibapp = validateAabPathSet([
        ...entries,
        'base/lib/arm64-v8a/libapp.so',
      ], spec: const AabLayoutSpec(abis: ['arm64-v8a'], requireLibapp: true));
      expect(withLibapp.ok, isTrue);
    });

    test('multi-dex accepted', () {
      final v = validateAabPathSet([
        'BundleConfig.pb',
        'base/manifest/AndroidManifest.xml',
        'base/resources.pb',
        'base/dex/classes.dex',
        'base/dex/classes2.dex',
        'base/assets/flutter_assets/x',
        'base/lib/arm64-v8a/libflutter.so',
      ]);
      expect(v.ok, isTrue);
    });
  });

  group('stageAabBaseModule', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_aab_test');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test(
      'explodes proto ap into base/ with manifest under manifest/',
      () async {
        // Build a fake proto-format resources archive.
        final protoZip = File('${tmp.path}/resources_proto.ap_');
        final archive = Archive()
          ..addFile(ArchiveFile('AndroidManifest.xml', 4, [1, 2, 3, 4]))
          ..addFile(ArchiveFile('resources.pb', 2, [9, 9]))
          ..addFile(ArchiveFile('res/values/values.arsc.flat', 1, [7]));
        await protoZip.writeAsBytes(ZipEncoder().encodeBytes(archive));

        final dex = File('${tmp.path}/classes.dex');
        await dex.writeAsBytes([0x64, 0x65, 0x78]);
        final assetsDir = Directory('${tmp.path}/fa');
        await Directory('${assetsDir.path}/sub').create(recursive: true);
        await File('${assetsDir.path}/sub/a.txt').writeAsString('hi');

        final libflutter = File('${tmp.path}/libflutter.so');
        await libflutter.writeAsBytes([1, 2]);

        final baseDir = '${tmp.path}/aab/base';
        await stageAabBaseModule(
          baseDir: baseDir,
          protoResourcesAp: protoZip.path,
          dexFiles: [dex.path],
          flutterAssetsDir: assetsDir.path,
          libflutterByAbi: {'arm64-v8a': libflutter.path},
        );

        expect(
          File('$baseDir/manifest/AndroidManifest.xml').existsSync(),
          isTrue,
        );
        expect(File('$baseDir/AndroidManifest.xml').existsSync(), isFalse);
        expect(File('$baseDir/resources.pb').existsSync(), isTrue);
        expect(
          File('$baseDir/res/values/values.arsc.flat').existsSync(),
          isTrue,
        );
        expect(File('$baseDir/dex/classes.dex').existsSync(), isTrue);
        expect(
          File('$baseDir/assets/flutter_assets/sub/a.txt').existsSync(),
          isTrue,
        );
        expect(
          File('$baseDir/lib/arm64-v8a/libflutter.so').existsSync(),
          isTrue,
        );

        // Round-trip: zip + list + validate (BundleConfig.pb written like
        // the real packager does).
        await File(
          '${tmp.path}/aab/BundleConfig.pb',
        ).writeAsBytes(minimalBundleConfigPb());
        final aabPath = '${tmp.path}/out.aab';
        await zipBundle('${tmp.path}/aab', aabPath);
        final entries = await listAabEntries(aabPath);
        final validation = validateAabPathSet(entries);
        expect(validation.ok, isTrue, reason: validation.missing.join(', '));
      },
    );
  });
}
