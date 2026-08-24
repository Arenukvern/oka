import 'dart:io';

import 'package:oka/src/build/apk_layout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('listDexOutputs / multi-dex staging', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_multidex_');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('listDexOutputs finds classes.dex and classes2.dex', () async {
      final dexDir = Directory(p.join(tmp.path, 'dex'));
      await dexDir.create(recursive: true);
      await File(p.join(dexDir.path, 'classes.dex')).writeAsBytes([1, 2, 3]);
      await File(p.join(dexDir.path, 'classes2.dex')).writeAsBytes([4, 5, 6]);
      await File(p.join(dexDir.path, 'noise.txt')).writeAsString('x');

      final out = await listDexOutputs(dexDir.path);
      expect(out.map(p.basename).toList(), ['classes.dex', 'classes2.dex']);
    });

    test('stageApkLayout packages all multi-dex files into zip APK', () async {
      final dex1 = File(p.join(tmp.path, 'classes.dex'));
      final dex2 = File(p.join(tmp.path, 'classes2.dex'));
      // Embed fake class descriptor strings so anyDexContainsClass can find them
      final d1 = <int>[
        ...[0x64, 0x65, 0x78, 0x0a], // "dex\n"
        ...'Lfake/OnlyInDex1;'.codeUnits,
      ];
      final d2 = <int>[
        ...[0x64, 0x65, 0x78, 0x0a],
        ...'Lio/flutter/plugins/GeneratedPluginRegistrant;'.codeUnits,
        ...'Lio/flutter/plugins/sharedpreferences/SharedPreferencesPlugin;'
            .codeUnits,
      ];
      await dex1.writeAsBytes(d1);
      await dex2.writeAsBytes(d2);

      final assets = Directory(p.join(tmp.path, 'fa'));
      await assets.create();
      await File(p.join(assets.path, 'x')).writeAsString('y');
      final so = File(p.join(tmp.path, 'libflutter.so'));
      await so.writeAsBytes([0x7f, 0x45, 0x4c, 0x46]);

      final staging = p.join(tmp.path, 'staging');
      await stageApkLayout(
        stagingDir: staging,
        dexFiles: [dex1.path, dex2.path],
        flutterAssetsDir: assets.path,
        libflutterByAbi: {'arm64-v8a': so.path},
      );

      expect(await File(p.join(staging, 'classes.dex')).exists(), isTrue);
      expect(await File(p.join(staging, 'classes2.dex')).exists(), isTrue);

      final apk = p.join(tmp.path, 'app.apk');
      await zipStagingToApk(staging, apk);
      final entries = await listApkEntries(apk);
      final multi = multiDexEntries(entries);
      expect(multi, containsAll(['classes.dex', 'classes2.dex']));

      final blobs = await readApkDexBlobs(apk);
      expect(blobs.keys, containsAll(['classes.dex', 'classes2.dex']));
      expect(
        anyDexContainsClass(
          blobs.values,
          'io.flutter.plugins.GeneratedPluginRegistrant',
        ),
        isTrue,
      );
      expect(
        anyDexContainsClass(
          blobs.values,
          'io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin',
        ),
        isTrue,
      );
      // Must not be only in intermediate — must be in packaged APK blobs
      expect(
        anyDexContainsClass([
          blobs['classes.dex']!,
        ], 'io.flutter.plugins.GeneratedPluginRegistrant'),
        isFalse,
      );
      expect(
        anyDexContainsClass([
          blobs['classes2.dex']!,
        ], 'io.flutter.plugins.GeneratedPluginRegistrant'),
        isTrue,
      );
    });

    test('single-dex path still works when only classes.dex present', () async {
      final dex = File(p.join(tmp.path, 'classes.dex'));
      await dex.writeAsBytes([
        ...[0x64, 0x65, 0x78, 0x0a],
        ...'Lio/flutter/plugins/GeneratedPluginRegistrant;'.codeUnits,
      ]);
      final assets = Directory(p.join(tmp.path, 'fa2'));
      await assets.create();
      await File(p.join(assets.path, 'a')).writeAsString('b');
      final so = File(p.join(tmp.path, 'libflutter.so'));
      await so.writeAsBytes([1]);

      final staging = p.join(tmp.path, 's2');
      await stageApkLayout(
        stagingDir: staging,
        dexFile: dex.path,
        flutterAssetsDir: assets.path,
        libflutterByAbi: {'arm64-v8a': so.path},
      );
      final apk = p.join(tmp.path, 'one.apk');
      await zipStagingToApk(staging, apk);
      final multi = multiDexEntries(await listApkEntries(apk));
      expect(multi, ['classes.dex']);
    });
  });

  test(
    'flutter_apk_builder packages multi-dex list (source contract)',
    () async {
      final src = await File(
        p.join('lib', 'src', 'pipeline', 'toolchain.dart'),
      ).readAsString();
      expect(src, contains('listDexOutputs'));
      expect(src, contains('dexFiles:'));
      // Must not return a single classes.dex path only
      expect(src, contains('dexFiles'));
    },
  );
}
