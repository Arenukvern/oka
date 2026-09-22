import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_rustore/oka_rustore.dart';
import 'package:test/test.dart';

void main() {
  test('RuStore policy checks package, version, and signature', () {
    const policy = RuStoreDistributionPolicy(
      packageName: 'dev.example.app',
      minimumVersionCode: 4,
      versionNamePattern: '1.',
    );
    expect(
      policy
          .validate(
            const RuStoreArtifactMetadata(
              packageName: 'dev.example.app',
              versionCode: 3,
              versionName: '2.0',
              signatureEntries: [],
            ),
          )
          .length,
      3,
    );
  });

  test('target uses an opaque project-declared name', () {
    const target = RuStorePublishTarget(
      packageName: 'dev.example.app',
      targetName: 'release-rustore',
    );
    expect(target.name, 'release-rustore');
  });

  test('archive gate does not apply Play split semantics', () async {
    final dir = await Directory.systemTemp.createTemp('rustore-test-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/app.aab';
    final archive = Archive()
      ..addFile(ArchiveFile('base/manifest/AndroidManifest.xml', 1, [0]));
    await File(path).writeAsBytes(ZipEncoder().encode(archive));
    final issues = await verifyRuStoreAab(
      aabPath: path,
      policy: const RuStoreDistributionPolicy(packageName: 'app'),
      metadata: (_) => const RuStoreArtifactMetadata(
        packageName: 'app',
        versionCode: 1,
        versionName: '1',
        signatureEntries: ['META-INF/CERT.RSA'],
      ),
    );
    expect(issues, isEmpty);
  });
}
