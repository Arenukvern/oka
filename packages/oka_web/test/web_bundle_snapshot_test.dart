import 'dart:io';
import 'package:oka_web/oka_web.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('oka-snapshot-');
    await File('${root.path}/main.js').writeAsString('original');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'snapshot remains immutable after filesystem and caller mutations',
    () async {
      final manifest = await WebBundleManifest.capture(root);
      final snapshot = await WebBundleSnapshot.load(
        directory: root,
        manifest: manifest,
        maxBytes: 8,
      );
      await File('${root.path}/main.js').writeAsString('replacement');
      expect(snapshot.read('main.js'), 'original'.codeUnits);
      expect(() => snapshot.read('main.js')[0] = 0, throwsUnsupportedError);
      expect(
        () => snapshot.read('main.js').buffer.asUint8List()[0] = 0,
        throwsUnsupportedError,
      );
      expect(snapshot.read('main.js'), 'original'.codeUnits);
      expect(snapshot.byteLength, 8);
    },
  );

  test('budget and changed source refuse loading', () async {
    final manifest = await WebBundleManifest.capture(root);
    await expectLater(
      WebBundleSnapshot.load(directory: root, manifest: manifest, maxBytes: 7),
      throwsStateError,
    );
    await File('${root.path}/main.js').writeAsString('changed');
    await expectLater(
      WebBundleSnapshot.load(directory: root, manifest: manifest, maxBytes: 8),
      throwsStateError,
    );
  });

  test('asset routes require exact digest and manifest path', () async {
    final manifest = await WebBundleManifest.capture(root);
    final snapshot = await WebBundleSnapshot.load(
      directory: root,
      manifest: manifest,
      maxBytes: 8,
    );
    final uri = snapshot.assetUri('main.js');
    expect(snapshot.readAssetUri(uri), 'original'.codeUnits);
    for (final invalid in [
      Uri.parse('/bundles/wrong/main.js'),
      Uri.parse('/bundles/${snapshot.digest}/unknown.js'),
      uri.replace(query: 'revision=other'),
      Uri.parse('https://example.test$uri'),
      Uri.parse('/bundles/${snapshot.digest}/%2E%2E/main.js'),
    ]) {
      expect(() => snapshot.readAssetUri(invalid), throwsStateError);
    }
  });
}
