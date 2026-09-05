import 'dart:io';

import 'package:oka_android/src/build/apk_layout.dart';
import 'package:oka_android/src/build/flutter_assemble.dart';
import 'package:oka_core/src/config/build_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('release AOT packaging paths', () {
    test('AOT assemble args per multi-ABI config', () {
      final abis = resolveAbis(
        configAbis: ['arm64-v8a', 'armeabi-v7a'],
      );
      expect(abis, ['arm64-v8a', 'armeabi-v7a']);

      final commands = abis
          .map(
            (abi) => buildFlutterAotAssembleArgs(
              outputDir: 'build/aot/$abi',
              targetFile: 'lib/main.dart',
              abi: abi,
            ),
          )
          .toList();

      expect(
        commands[0],
        contains('android_aot_bundle_release_android-arm64'),
      );
      expect(
        commands[1],
        contains('android_aot_bundle_release_android-arm'),
      );
      for (final c in commands) {
        expect(c, isNot(contains('flutter build apk')));
        expect(c.first, 'assemble');
      }
    });

    test('stage layout with libapp.so for release multi-abi', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_release_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      final so = File(p.join(tmp.path, 'libflutter.so'));
      await so.writeAsBytes([1]);
      final appSo = File(p.join(tmp.path, 'app.so'));
      await appSo.writeAsBytes([2]);
      final assets = Directory(p.join(tmp.path, 'fa'));
      await assets.create();
      await File(p.join(assets.path, 'AssetManifest.bin')).writeAsBytes([0]);
      final dex = File(p.join(tmp.path, 'classes.dex'));
      await dex.writeAsBytes([0x64, 0x65, 0x78, 0x0a]);

      final abis = resolveAbis(
        configAbis: ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
      );
      final staging = p.join(tmp.path, 'staging');
      await stageApkLayout(
        stagingDir: staging,
        dexFile: dex.path,
        flutterAssetsDir: assets.path,
        libflutterByAbi: {for (final a in abis) a: so.path},
        libappByAbi: {for (final a in abis) a: appSo.path},
      );

      final v = await validateStagingLayout(
        staging,
        spec: ApkLayoutSpec(abis: abis, requireLibapp: true),
      );
      expect(v.ok, isTrue, reason: '${v.missing}');

      // Map config target_abi single override for release
      final single = resolveAbis(
        configAbis: abis,
        targetAbi: 'android-arm64',
      );
      expect(single, ['arm64-v8a']);
    });

    test('findLibappSo finds app.so under nested output', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_aot_find_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final nested = Directory(p.join(tmp.path, 'arm64-v8a'));
      await nested.create(recursive: true);
      await File(p.join(nested.path, 'app.so')).writeAsBytes([9]);

      final found = await findLibappSo(tmp.path);
      expect(found, isNotNull);
      expect(found, endsWith('app.so'));
    });
  });

  group('BuildMode release assemble target', () {
    test('release application target name', () {
      expect(
        androidApplicationTarget(BuildMode.release),
        'release_android_application',
      );
      expect(assembleBuildMode(BuildMode.release), 'release');
    });
  });
}
