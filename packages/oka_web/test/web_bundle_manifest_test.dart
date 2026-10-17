import 'dart:io';
import 'package:oka_web/oka_web.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('oka-bundle-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  Future<void> write(String path, String text) async {
    final file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  test(
    'content identity survives serialization and timestamp-only changes',
    () async {
      await write('z.js', 'code');
      await write('assets/font.bin', 'font');
      final manifest = await WebBundleManifest.capture(root);
      final restored = WebBundleManifest.fromJson(manifest.toJson());
      expect(restored.digest, manifest.digest);
      expect(restored.files.keys, ['assets/font.bin', 'z.js']);
      await File('${root.path}/z.js').setLastModified(DateTime(2000));
      expect(await restored.matches(root), isTrue);
      expect(await restored.readVerified(root, 'z.js'), 'code'.codeUnits);
    },
  );
  test('changed bytes, added and removed assets invalidate identity', () async {
    await write('main.js', 'original');
    final manifest = await WebBundleManifest.capture(root);
    await write('main.js', 'modified');
    expect(await manifest.matches(root), isFalse);
    await expectLater(manifest.readVerified(root, 'main.js'), throwsStateError);
    await write('main.js', 'original');
    await write('new.bin', 'new');
    expect(await manifest.matches(root), isFalse);
    await File('${root.path}/new.bin').delete();
    expect(await manifest.matches(root), isTrue);
    await File('${root.path}/main.js').delete();
    await expectLater(manifest.matches(root), throwsStateError);
  });
  test('manifest digest tampering and traversal are refused', () async {
    await write('main.js', 'code');
    final manifest = await WebBundleManifest.capture(root);
    expect(
      () => WebBundleManifest.fromJson({...manifest.toJson(), 'digest': 'bad'}),
      throwsFormatException,
    );
    await expectLater(
      manifest.readVerified(root, '../main.js'),
      throwsStateError,
    );
    await expectLater(
      manifest.readVerified(root, 'unknown.js'),
      throwsStateError,
    );
  });
  test(
    'symlink capture and post-capture symlink replacement are refused',
    () async {
      await write('main.js', 'code');
      final manifest = await WebBundleManifest.capture(root);
      await write('other.js', 'code');
      await File('${root.path}/main.js').delete();
      await Link('${root.path}/main.js').create('${root.path}/other.js');
      await expectLater(WebBundleManifest.capture(root), throwsStateError);
      await expectLater(
        manifest.readVerified(root, 'main.js'),
        throwsStateError,
      );
    },
  );
}
