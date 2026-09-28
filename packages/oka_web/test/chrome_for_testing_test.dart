import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_core/oka_core.dart';
import 'package:oka_web/src/session/chrome_for_testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka_cft_');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  group('pure layout functions', () {
    test('platform mapping', () {
      expect(
        chromeForTestingPlatform(
          operatingSystem: 'macos',
          abi: Abi.macosArm64,
        ),
        'mac-arm64',
      );
      expect(
        chromeForTestingPlatform(operatingSystem: 'macos', abi: Abi.macosX64),
        'mac-x64',
      );
      expect(
        chromeForTestingPlatform(operatingSystem: 'linux', abi: Abi.linuxX64),
        'linux64',
      );
      expect(chromeForTestingPlatform(operatingSystem: 'windows'), 'win64');
    });

    test('binary-in-archive layout per platform', () {
      // Path contains real spaces — lint false positive.
      expect(
        chromeForTestingBinaryInArchive('mac-arm64'),
        // Path contains real spaces — lint false positive.
        // ignore: missing_whitespace_between_adjacent_strings
        'mac-arm64/Google Chrome for Testing.app/Contents/MacOS/'
        'Google Chrome for Testing',
      );
      expect(chromeForTestingBinaryInArchive('linux64'), 'chrome-linux64/chrome');
      expect(
        chromeForTestingBinaryInArchive('win64'),
        'chrome-win64/chrome.exe',
      );
    });

    test('download url is version+platform pinned', () {
      expect(
        chromeForTestingDownloadUrl(version: '138.0.0.0', platform: 'mac-arm64'),
        'https://storage.googleapis.com/chrome-for-testing-public/'
        '138.0.0.0/mac-arm64/chrome-mac-arm64.zip',
      );
    });
  });

  group('provisioner', () {
    ChromeForTestingProvisioner provisioner({
      required String version,
      String platform = 'linux64',
    }) {
      final zip = Archive()
        ..addFile(
          ArchiveFile('chrome-$platform/chrome', 19, 'fake browser binary'.codeUnits),
        );
      return ChromeForTestingProvisioner(
        store: LocalArtifactStore(root: p.join(temp.path, 'store')),
        toolsRoot: p.join(temp.path, 'tools', 'chrome-for-testing'),
        platform: platform,
        fetchText: (final url) async =>
            jsonEncode({'channels': {'Stable': {'version': version}}}),
        fetchBytes: (final url) async => ZipEncoder().encodeBytes(zip),
      );
    }

    test('provision downloads through the store and extracts the binary',
        () async {
      final cft = provisioner(version: '138.0.1.2');
      final binary = await cft.provision();
      expect(binary, contains('138.0.1.2-linux64'));
      expect(File(binary).readAsStringSync(), 'fake browser binary');
      // Store entry visible for oka cache list/gc.
      final entries = await cft.store.entries();
      expect(
        entries.where((final e) => e.key.category == 'chrome-for-testing'),
        isNotEmpty,
      );
    });

    test('second provision is a store hit (no re-extract)', () async {
      final cft = provisioner(version: '138.0.1.2');
      final first = await cft.provision();
      final mtime = File(first).statSync().modified;
      final second = await cft.provision();
      expect(second, first);
      expect(File(second).statSync().modified, mtime);
    });

    test('resolveBinary: explicit path wins over everything', () async {
      final explicit = File(p.join(temp.path, 'my-chrome'))
        ..writeAsStringSync('x');
      final cft = provisioner(version: '138.0.1.2');
      final resolved = await cft.resolveBinary(
        explicitPath: explicit.path,
        environment: {'HOME': temp.path},
      );
      expect(resolved, explicit.path);
    });

    test('resolveBinary: OKA_CHROME_BIN wins over provisioned', () async {
      final envBin = File(p.join(temp.path, 'env-chrome'))
        ..writeAsStringSync('x');
      final cft = provisioner(version: '138.0.1.2');
      // Provision first so a provisioned binary exists.
      await cft.provision();
      final resolved = await cft.resolveBinary(
        environment: {'HOME': temp.path, 'OKA_CHROME_BIN': envBin.path},
      );
      expect(resolved, envBin.path);
    });

    test('resolveBinary finds a previously provisioned build without network',
        () async {
      final cft = provisioner(version: '138.0.1.2');
      final provisioned = await cft.provision();
      // A fresh provisioner instance over the same roots — no fetches
      // needed; the fake fetchers would throw on any use.
      final fresh = ChromeForTestingProvisioner(
        store: cft.store,
        toolsRoot: cft.toolsRoot,
        platform: cft.platform,
        fetchText: (final _) async => fail('network used'),
        fetchBytes: (final _) async => fail('network used'),
      );
      final resolved = await fresh.resolveBinary(environment: {
        'HOME': temp.path,
        // Keep the provisioner away from any real system Chrome.
        'OKA_NO_AUTO_INSTALL': '1',
      });
      expect(resolved, provisioned);
    });
  });
}
