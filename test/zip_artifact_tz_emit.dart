// Subprocess helper for cross-timezone APK/AAB determinism (parent orchestrates).
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:oka_android/src/build/aab_layout.dart' show zipBundle;
import 'package:oka_android/src/build/apk_layout.dart';
import 'package:path/path.dart' as p;

import 'zip_raw_headers.dart';

Future<void> main() async {
  final tmp = await Directory.systemTemp.createTemp('oka-zip-tz-emit-');
  try {
    final staging = Directory(p.join(tmp.path, 'staging'));
    for (final rel in ['AndroidManifest.xml', 'classes.dex']) {
      final f = File(p.join(staging.path, rel));
      await f.parent.create(recursive: true);
      await f.writeAsBytes(List.filled(rel.length, 7));
    }
    final apkPath = p.join(tmp.path, 'out.apk');
    await zipStagingToApk(staging.path, apkPath);
    final apkBytes = await File(apkPath).readAsBytes();

    final bundle = Directory(p.join(tmp.path, 'bundle'));
    final manifest = File(p.join(bundle.path, 'base/manifest/AndroidManifest.xml'));
    await manifest.parent.create(recursive: true);
    await manifest.writeAsBytes([1, 2, 3]);
    final aabPath = p.join(tmp.path, 'out.aab');
    await zipBundle(bundle.path, aabPath);
    final aabBytes = await File(aabPath).readAsBytes();

    List<Map<String, dynamic>> metaJson(List<ZipRawEntryMeta> rows) => [
          for (final e in rows)
            {
              'name': e.name,
              'dosTime': e.dosTime,
              'dosDate': e.dosDate,
              'utSeconds': e.utSeconds,
              'fromCentral': e.fromCentral,
            },
        ];

    print(
      jsonEncode({
        'tz': Platform.environment['TZ'],
        'apk': {
          'sha256': sha256.convert(apkBytes).toString(),
          'base64': base64Encode(apkBytes),
          'local': metaJson(zipRawLocalEntryMetadata(apkBytes)),
          'central': metaJson(zipRawCentralEntryMetadata(apkBytes)),
        },
        'aab': {
          'sha256': sha256.convert(aabBytes).toString(),
          'base64': base64Encode(aabBytes),
          'local': metaJson(zipRawLocalEntryMetadata(aabBytes)),
          'central': metaJson(zipRawCentralEntryMetadata(aabBytes)),
        },
      }),
    );
  } finally {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  }
}
