import 'dart:io';

import 'package:oka_android/src/build/sdk_locator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('validatePackagingTools vs adb', () {
    test('source: packaging validation does not call findAdb', () async {
      // ADR-0013 T1: tool resolution moved from sdk_locator.dart to
      // toolchain.dart — the invariants hold on the new policy file.
      final toolchainSrc = await File(
        p.join('packages', 'oka_android', 'lib', 'src', 'build', 'toolchain.dart'),
      ).readAsString();

      // Extract validatePackagingTools body roughly
      final start = toolchainSrc.indexOf('validatePackagingTools()');
      expect(start, greaterThan(0));
      final end = toolchainSrc.indexOf('validateTools(', start);
      expect(end, greaterThan(start));
      final body = toolchainSrc.substring(start, end);
      expect(body, contains('findAapt2'));
      expect(body, contains('findD8'));
      expect(body, contains('findZipalign'));
      expect(body, contains('findApksigner'));
      expect(body, isNot(contains('findAdb')));
    });

    test(
      'source: EnsureAndroidSdkStep uses validatePackagingTools not adb-required',
      () async {
        final text = await File(
          p.join('packages', 'oka_android', 'lib', 'src', 'pipeline', 'steps', 'host_steps.dart'),
        ).readAsString();
        expect(text, contains('validatePackagingTools'));
        // Must not require full validateTools() for packaging gate
        expect(text.contains('validatePackagingTools()'), isTrue);
      },
    );

    test('validateTools treats adb as optional by default', () async {
      final toolchainSrc = await File(
        p.join('packages', 'oka_android', 'lib', 'src', 'build', 'toolchain.dart'),
      ).readAsString();
      expect(toolchainSrc, contains('requireAdb = false'));
      // optional catch around findAdb
      expect(toolchainSrc, contains('Optional for packaging-only flows'));
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

    test('SdkLocator is a thin wrapper over ResolvedToolchain (ADR-0013)',
        () async {
      // The deprecated wrapper must not reimplement resolution — it only
      // forwards constructor args to the data-driven policy.
      final wrapperSrc = await File(
        p.join('packages', 'oka_android', 'lib', 'src', 'build', 'sdk_locator.dart'),
      ).readAsString();
      expect(wrapperSrc, contains('extends ResolvedToolchain'));
      expect(wrapperSrc, isNot(contains('Future<String> find')));
      expect(wrapperSrc, isNot(contains('Platform.environment')));
    });
  });
}
