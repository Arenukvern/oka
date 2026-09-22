import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('validates DEX magic and contiguous classes files', () async {
    final dir = await Directory.systemTemp.createTemp('oka-aab-test-');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'app.aab');
    await _writeBundle(path, {
      'BundleConfig.pb': [1],
      'base/manifest/AndroidManifest.xml': [0x0a, 0x01, 0x78],
      'base/resources.pb': [1],
      'base/dex/classes.dex': [0x64, 0x65, 0x78, 0x0a, 0x30, 0x33, 0x35, 0],
      'base/dex/classes3.dex': [0x64, 0x65, 0x78, 0x0a, 0x30, 0x33, 0x35, 0],
      'base/assets/flutter_assets/AssetManifest.json': [1],
      'base/lib/arm64-v8a/libflutter.so': [1],
    });

    final result = await validateAabFile(path);
    expect(result.ok, isFalse);
    expect(result.errors, contains(contains('missing classes2.dex')));
  });

  test('requires all parts of a v1 signature when requested', () async {
    final dir = await Directory.systemTemp.createTemp('oka-aab-test-');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'app.aab');
    await _writeBundle(path, {
      'BundleConfig.pb': [1],
      'base/manifest/AndroidManifest.xml': [0x0a, 0x01, 0x78],
      'base/resources.pb': [1],
      'base/dex/classes.dex': [0x64, 0x65, 0x78, 0x0a, 0x30, 0x33, 0x35, 0],
      'base/assets/flutter_assets/AssetManifest.json': [1],
      'base/lib/arm64-v8a/libflutter.so': [1],
    });

    final result = await validateAabFile(
      path,
      spec: const AabLayoutSpec(requireSignature: true),
    );
    expect(result.ok, isFalse);
    expect(result.errors, contains(contains('not v1 signed')));
  });
}

Future<void> _writeBundle(String path, Map<String, List<int>> entries) async {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  await File(path).writeAsBytes(ZipEncoder().encodeBytes(archive));
}
