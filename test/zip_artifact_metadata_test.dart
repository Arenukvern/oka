import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/src/build/aab_layout.dart' show zipBundle;
import 'package:oka_android/src/build/apk_layout.dart';
import 'package:oka_android/src/build/zip_artifact_time.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'zip_raw_headers.dart';

/// Decodes central-directory [lastModTime] values from a zip artifact.
List<int> zipEntryUnixTimes(List<int> zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  return [
    for (final f in archive.files.where((e) => e.isFile)) f.lastModTime,
  ];
}

Map<String, dynamic> _runTzEmit(String tz) {
  final result = Process.runSync(
    Platform.executable,
    ['run', 'test/zip_artifact_tz_emit.dart'],
    workingDirectory: Directory.current.path,
    environment: {...Platform.environment, 'TZ': tz},
  );
  expect(
    result.exitCode,
    0,
    reason: 'TZ=$tz emit failed\n${result.stdout}\n${result.stderr}',
  );
  return jsonDecode(result.stdout as String) as Map<String, dynamic>;
}

void main() {
  final root = Directory.current.path;

  test('archive constraint and resolved version are at least 4.6.0', () {
    final androidPub =
        File('$root/packages/oka_android/pubspec.yaml').readAsStringSync();
    final constraint = RegExp(r'archive:\s*\^(\d+\.\d+\.\d+)')
        .firstMatch(androidPub)!
        .group(1)!;
    final constraintParts = constraint.split('.').map(int.parse).toList();
    expect(
      constraintParts[0] > 4 ||
          (constraintParts[0] == 4 && constraintParts[1] >= 6),
      isTrue,
      reason: 'packages/oka_android must require archive ^4.6.0+',
    );
    final config = jsonDecode(
      File('$root/.dart_tool/package_config.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final archiveRoot =
        (config['packages'] as List).cast<Map<String, dynamic>>().firstWhere(
      (e) => e['name'] == 'archive',
    )['rootUri'] as String;
    final pkgDir = Uri.parse(archiveRoot).toFilePath(windows: Platform.isWindows);
    final resolved = RegExp(r'^version:\s*(\S+)', multiLine: true)
        .firstMatch(File('$pkgDir/pubspec.yaml').readAsStringSync())!
        .group(1)!;
    final resolvedParts = resolved.split('.').map(int.parse).toList();
    expect(
      resolvedParts[0] > 4 ||
          (resolvedParts[0] == 4 && resolvedParts[1] >= 6),
      isTrue,
      reason: 'resolved archive $resolved < 4.6.0',
    );
  });

  group('ADR-0007 zip entry metadata', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka-zip-meta-');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<String> packApk() async {
      final staging = Directory(p.join(tmp.path, 'staging'));
      for (final rel in ['AndroidManifest.xml', 'classes.dex']) {
        final f = File(p.join(staging.path, rel));
        await f.parent.create(recursive: true);
        await f.writeAsBytes(List.filled(rel.length, 7));
      }
      final apk = p.join(tmp.path, 'out.apk');
      await zipStagingToApk(staging.path, apk);
      return apk;
    }

    void expectCanonicalRawHeaders(List<int> bytes) {
      final locals = zipRawLocalEntryMetadata(bytes);
      final centrals = zipRawCentralEntryMetadata(bytes);
      expect(locals, isNotEmpty);
      expect(centrals.length, locals.length);
      for (final row in locals) {
        expect(row.dosTime, 0, reason: '${row.name} local DOS time');
        expect(row.dosDate, 0x21, reason: '${row.name} local DOS date');
      }
      for (final row in centrals) {
        expect(row.dosTime, 0, reason: '${row.name} central DOS time');
        expect(row.dosDate, 0x21, reason: '${row.name} central DOS date');
        expect(row.utSeconds, okaZipEntryUnixSeconds,
            reason: '${row.name} central UT extra');
      }
      final zipDecoded = zipEntryUnixTimes(bytes);
      expect(zipDecoded, everyElement(okaZipEntryUnixSeconds));
    }

    test('APK entries use canonical DOS/UT metadata', () async {
      final bytes = await File(await packApk()).readAsBytes();
      expectCanonicalRawHeaders(bytes);
    });

    test('AAB entries use canonical DOS/UT metadata', () async {
      final bundle = Directory(p.join(tmp.path, 'bundle'));
      for (final rel in ['base/manifest/AndroidManifest.xml']) {
        final f = File(p.join(bundle.path, rel));
        await f.parent.create(recursive: true);
        await f.writeAsBytes([1, 2, 3]);
      }
      final aab = p.join(tmp.path, 'out.aab');
      await zipBundle(bundle.path, aab);
      expectCanonicalRawHeaders(await File(aab).readAsBytes());
    });

    test('APK bytes identical across wall-clock gap (pinned metadata)', () async {
      final staging = Directory(p.join(tmp.path, 'stg'));
      final dex = File(p.join(staging.path, 'classes.dex'));
      await dex.parent.create(recursive: true);
      await dex.writeAsBytes([9]);
      final apk1 = p.join(tmp.path, '1.apk');
      final apk2 = p.join(tmp.path, '2.apk');
      await zipStagingToApk(staging.path, apk1);
      await Future<void>.delayed(const Duration(seconds: 2));
      await zipStagingToApk(staging.path, apk2);
      expect(await File(apk1).readAsBytes(), await File(apk2).readAsBytes());
    });

    test('default ArchiveFile timestamps drift across wall-clock gap', () async {
      final archive = Archive()
        ..addFile(ArchiveFile('only.txt', 3, [1, 2, 3]));
      final zip1 = ZipEncoder().encodeBytes(archive);
      await Future<void>.delayed(const Duration(seconds: 2));
      final zip2 = ZipEncoder().encodeBytes(
        Archive()..addFile(ArchiveFile('only.txt', 3, [1, 2, 3])),
      );
      expect(zip1, isNot(equals(zip2)),
          reason: 'unpinned metadata must differ (proves stamp is load-bearing)');
    });
  });

  test(
    'APK and AAB bytes match across UTC, America/Los_Angeles, and Asia/Tokyo',
    () {
      final zones = ['UTC', 'America/Los_Angeles', 'Asia/Tokyo'];
      final payloads = {for (final tz in zones) tz: _runTzEmit(tz)};
      final reference = payloads['UTC']!;
      for (final tz in zones) {
        final row = payloads[tz]!;
        expect(
          (row['apk'] as Map)['sha256'],
          (reference['apk'] as Map)['sha256'],
          reason: 'APK sha256 mismatch TZ=$tz',
        );
        expect(
          (row['aab'] as Map)['sha256'],
          (reference['aab'] as Map)['sha256'],
          reason: 'AAB sha256 mismatch TZ=$tz',
        );
        expect(
          (row['apk'] as Map)['base64'],
          (reference['apk'] as Map)['base64'],
          reason: 'full APK bytes mismatch TZ=$tz',
        );
        expect(
          (row['aab'] as Map)['base64'],
          (reference['aab'] as Map)['base64'],
          reason: 'full AAB bytes mismatch TZ=$tz',
        );
        for (final artifact in ['apk', 'aab']) {
          final art = row[artifact] as Map<String, dynamic>;
          final local = (art['local'] as List).cast<Map<String, dynamic>>();
          final central = (art['central'] as List).cast<Map<String, dynamic>>();
          expect(local, isNotEmpty, reason: '$artifact local TZ=$tz');
          expect(central, isNotEmpty, reason: '$artifact central TZ=$tz');
          for (final h in local) {
            expect(h['dosTime'], 0, reason: '$artifact ${h['name']} TZ=$tz');
            expect(h['dosDate'], 0x21);
          }
          for (final h in central) {
            expect(h['dosTime'], 0);
            expect(h['dosDate'], 0x21);
            expect(h['utSeconds'], okaZipEntryUnixSeconds);
          }
        }
      }
    },
    skip: Platform.environment['OKA_ZIP_TZ_PROBE'] == '1' ? 'TZ probe child' : false,
  );
}
