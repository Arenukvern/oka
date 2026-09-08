import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/src/build/bundletool.dart';
import 'package:test/test.dart';

void main() {
  group('extractUniversalApk', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_bundletool_test');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('extracts splits/universal.apk from an .apks archive', () async {
      final apks = File('${tmp.path}/test.apks');
      final archive = Archive()
        ..addFile(ArchiveFile('toc.pb', 2, [1, 1]))
        ..addFile(ArchiveFile('splits/base-master.apk', 3, [7, 7, 7]))
        ..addFile(ArchiveFile('splits/universal.apk', 5, [1, 2, 3, 4, 5]));
      await apks.writeAsBytes(ZipEncoder().encodeBytes(archive));

      final dest = '${tmp.path}/universal.apk';
      final out = await extractUniversalApk(apks.path, dest);
      expect(out, dest);
      expect(await File(dest).length(), 5);
    });

    test('throws when universal.apk missing', () async {
      final apks = File('${tmp.path}/test.apks');
      final archive = Archive()
        ..addFile(ArchiveFile('splits/base-master.apk', 1, [1]));
      await apks.writeAsBytes(ZipEncoder().encodeBytes(archive));

      expect(
        () => extractUniversalApk(apks.path, '${tmp.path}/u.apk'),
        throwsException,
      );
    });
  });

  group('findBundletool', () {
    test('returns null when nothing installed (no env override)', () async {
      // Only valid when OKA_BUNDLETOOL_JAR unset and ~/.oka/tools absent.
      if (Platform.environment['OKA_BUNDLETOOL_JAR'] != null) return;
      final defaultPath = defaultBundletoolJarPath();
      if (await File(defaultPath).exists()) return;
      final found = await findBundletool(explicitPath: '');
      expect(found, isNull);
    });
  });
}
