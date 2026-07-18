import 'dart:io';

import 'package:oka/src/build/sdk_locator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('validatePackagingTools vs adb', () {
    test('source: packaging validation does not call findAdb', () async {
      final locatorSrc = await File(
        p.join('lib', 'src', 'build', 'sdk_locator.dart'),
      ).readAsString();

      // Extract validatePackagingTools body roughly
      final start = locatorSrc.indexOf('validatePackagingTools()');
      expect(start, greaterThan(0));
      final end = locatorSrc.indexOf('validateTools(', start);
      expect(end, greaterThan(start));
      final body = locatorSrc.substring(start, end);
      expect(body, contains('findAapt2'));
      expect(body, contains('findD8'));
      expect(body, contains('findZipalign'));
      expect(body, contains('findApksigner'));
      expect(body, isNot(contains('findAdb')));
    });

    test('source: FlutterApkBuilder uses validatePackagingTools not adb-required',
        () async {
      final text = await File(
        p.join('lib', 'src', 'build', 'flutter_apk_builder.dart'),
      ).readAsString();
      expect(text, contains('validatePackagingTools'));
      // Must not require full validateTools() for packaging gate
      expect(
        text.contains('validatePackagingTools()'),
        isTrue,
      );
    });

    test('validateTools treats adb as optional by default', () async {
      final locatorSrc = await File(
        p.join('lib', 'src', 'build', 'sdk_locator.dart'),
      ).readAsString();
      expect(locatorSrc, contains('requireAdb = false'));
      // optional catch around findAdb
      expect(locatorSrc, contains('Optional for packaging-only flows'));
    });

    test('validatePackagingTools fails clearly without Android SDK', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_no_sdk_');
      addTearDown(() async {
        if (await tmp.exists()) {
          await tmp.delete(recursive: true);
        }
      });

      final locator = SdkLocator(
        androidSdkPath: p.join(tmp.path, 'missing_sdk'),
      );
      await expectLater(
        locator.validatePackagingTools(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString().toLowerCase(),
            'msg',
            contains('android sdk'),
          ),
        ),
      );
    });
  });
}
