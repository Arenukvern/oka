import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  test('release report is stable and machine-readable', () {
    const report = DeliveryVerificationReport(
      artifact: 'build/app.aab',
      artifactSha256: 'abc',
      artifactBytes: 42,
      abis: ['arm64-v8a'],
      gates: {'artifact_exists': true, 'bundletool_validate': true},
      metadata: {'zip_entries': 3},
    );
    expect(report.ok, isTrue);
    expect(report.toJson()['artifact_sha256'], 'abc');
    expect(report.toJson()['gates'], containsPair('bundletool_validate', true));
  });

  test('offline delivery verification hashes bundle and discovers ABIs', () async {
    final dir = await Directory.systemTemp.createTemp('oka-release-test');
    addTearDown(() => dir.delete(recursive: true));
    final aab = File('${dir.path}/app.aab');
    final archive = Archive()
      ..addFile(ArchiveFile('base/lib/arm64-v8a/libapp.so', 1, [0]));
    await aab.writeAsBytes(ZipEncoder().encode(archive));
    final report = await verifyAndroidDelivery(
      aabPath: aab.path,
      outputDirectory: dir.path,
      runBundletool: (args) async {
        if (args.first == 'validate') {
          return const BundletoolCommandResult(
            exitCode: 0,
            stdout: '',
            stderr: '',
          );
        }
        return const BundletoolCommandResult(
          exitCode: 1,
          stdout: '',
          stderr: 'not requested',
        );
      },
    );
    expect(report.ok, isTrue);
    expect(report.abis, ['arm64-v8a']);
    expect(report.artifactSha256, hasLength(64));
  });
}
