import 'dart:io';

import 'package:oka/src/build/android_sdk_installer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('commandLineToolsDownloadUrl / packagingSdkPackages', () {
    test('url contains host os and version', () {
      final url = commandLineToolsDownloadUrl(osOverride: 'mac', version: '1');
      expect(url, contains('commandlinetools-mac-1_latest.zip'));
      expect(url, startsWith('https://dl.google.com/android/repository/'));
    });

    test('packaging packages include build-tools and platform', () {
      final pkgs = packagingSdkPackages(buildTools: '35.0.0', platformApi: '34');
      expect(pkgs, contains('build-tools;35.0.0'));
      expect(pkgs, contains('platforms;android-34'));
      expect(pkgs, contains('platforms;android-36'));
      expect(pkgs, contains('platform-tools'));
    });
  });

  group('AndroidSdkInstaller cleanup', () {
    test('refuses non-managed root without force', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_sdk_clean_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      await File(p.join(tmp.path, 'build-tools', 'x')).create(recursive: true);

      final installer = AndroidSdkInstaller(sdkRoot: tmp.path);
      final result = await installer.cleanup();
      expect(result.success, isFalse);
      expect(result.message, contains('not oka-managed'));
      expect(await Directory(tmp.path).exists(), isTrue);
    });

    test('removes oka-managed root', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_sdk_managed_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      await File(p.join(tmp.path, kOkaSdkMarkerName))
          .writeAsString('managed_by=oka\n');
      await File(p.join(tmp.path, 'build-tools', 'a')).create(recursive: true);

      final installer = AndroidSdkInstaller(sdkRoot: tmp.path);
      final result = await installer.cleanup();
      expect(result.success, isTrue);
      expect(await Directory(tmp.path).exists(), isFalse);
    });
  });

  group('packagingToolsPresent', () {
    test('false when empty', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_sdk_empty_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      expect(await packagingToolsPresent(tmp.path), isFalse);
    });

    test('true when layout has tools + platform jar', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_sdk_ok_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final bt = p.join(tmp.path, 'build-tools', '34.0.0');
      await Directory(bt).create(recursive: true);
      for (final t in ['aapt2', 'd8', 'zipalign', 'apksigner']) {
        await File(p.join(bt, t)).writeAsString('x');
      }
      final plat = p.join(tmp.path, 'platforms', 'android-34');
      await Directory(plat).create(recursive: true);
      await File(p.join(plat, 'android.jar')).writeAsBytes([1, 2, 3]);

      expect(await packagingToolsPresent(tmp.path), isTrue);
    });
  });

  test('defaultOkaAndroidSdkRoot ends with .oka/android-sdk', () {
    expect(defaultOkaAndroidSdkRoot(), contains('.oka'));
    expect(defaultOkaAndroidSdkRoot(), endsWith('android-sdk'));
  });
}
