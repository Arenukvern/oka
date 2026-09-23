import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_rustore/oka_rustore.dart';
import 'package:test/test.dart';

void main() {
  test('RuStore config policy checks package, versions, and pattern', () {
    const policy = RuStoreDistributionPolicy(
      packageName: 'dev.example.app',
      minimumVersionCode: 4,
      versionNamePattern: '1.',
    );
    expect(
      policy
          .validateConfig(
            packageName: 'other.app',
            versionCode: 3,
            versionName: '2.0',
          )
          .length,
      3,
    );
    // Declared-but-unset versionCode is fine unless the policy pins a range.
    expect(
      policy
          .validateConfig(
            packageName: 'dev.example.app',
            versionCode: null,
            versionName: '',
          )
          .where((final i) => i.contains('versionCode')),
      isEmpty,
    );
  });

  test('target uses an opaque project-declared name', () {
    const target = RuStorePublishTarget(
      packageName: 'dev.example.app',
      targetName: 'release-rustore',
    );
    expect(target.name, 'release-rustore');
  });

  test('real mode without a credential adapter is refused at plan time', () {
    const target = RuStorePublishTarget(
      packageName: 'dev.example.app',
      dryRun: false,
    );
    expect(target.validateRealMode(), isNotEmpty);
  });

  test('real mode refuses policy-violating declared config at plan time', () {
    const target = RuStorePublishTarget(
      packageName: 'dev.example.app',
      dryRun: false,
      policy: RuStoreDistributionPolicy(
        packageName: 'dev.example.app',
        minimumVersionCode: 10,
      ),
      versionCode: 3,
    );
    expect(
      target.validateRealMode().any(
        (final issue) => issue.contains('below 10'),
      ),
      isTrue,
    );
  });

  test('archive gate checks real bundle facts only', () async {
    final dir = await Directory.systemTemp.createTemp('rustore-test-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/app.aab';
    final archive = Archive()
      ..addFile(ArchiveFile('base/manifest/AndroidManifest.xml', 1, [0]))
      ..addFile(ArchiveFile('META-INF/CERT.RSA', 1, [0]));
    await File(path).writeAsBytes(ZipEncoder().encode(archive));
    final issues = await verifyRuStoreAab(
      aabPath: path,
      policy: const RuStoreDistributionPolicy(packageName: 'app'),
    );
    expect(issues, isEmpty);
  });

  test('archive gate flags a missing v1 signature', () async {
    final dir = await Directory.systemTemp.createTemp('rustore-test-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/app.aab';
    final archive = Archive()
      ..addFile(ArchiveFile('base/manifest/AndroidManifest.xml', 1, [0]));
    await File(path).writeAsBytes(ZipEncoder().encode(archive));
    final issues = await verifyRuStoreAab(
      aabPath: path,
      policy: const RuStoreDistributionPolicy(packageName: 'app'),
    );
    expect(issues.single, contains('signature'));
  });
}
