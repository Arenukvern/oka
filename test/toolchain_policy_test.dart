import 'dart:io';

import 'package:oka_android/src/build/toolchain.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// ADR-0013 T1: toolchain resolution as data — precedence-policy unit tests
/// with injected env (no real machine state), version-selection regressions,
/// and doctor output format.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_toolchain_');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
  });

  /// Creates a fake Android SDK with [versions] build-tools dirs, each
  /// containing [binaries].
  Future<String> makeSdk(
    String name, {
    List<String> versions = const ['34.0.0'],
    List<String> binaries = const ['aapt2', 'd8', 'zipalign', 'apksigner'],
    bool platformTools = false,
  }) async {
    final sdk = Directory(p.join(tmp.path, name))..createSync(recursive: true);
    for (final v in versions) {
      final bt = Directory(p.join(sdk.path, 'build-tools', v))
        ..createSync(recursive: true);
      for (final b in binaries) {
        File(p.join(bt.path, b)).writeAsStringSync('#!/bin/sh\n');
      }
    }
    if (platformTools) {
      Directory(p.join(sdk.path, 'platform-tools')).createSync(recursive: true);
      File(p.join(sdk.path, 'platform-tools', 'adb'))
          .writeAsStringSync('#!/bin/sh\n');
    }
    return sdk.path;
  }

  ToolchainEnv env({
    String? okaAndroidSdk,
    String? androidHome,
    String? androidSdkRoot,
    String? javaHome,
    String? kotlinHome,
    String? path,
  }) {
    final values = <String, String>{
      'OKA_ANDROID_SDK': ?okaAndroidSdk,
      'ANDROID_HOME': ?androidHome,
      'ANDROID_SDK_ROOT': ?androidSdkRoot,
      'JAVA_HOME': ?javaHome,
      'KOTLIN_HOME': ?kotlinHome,
      'PATH': ?path,
    };
    return ToolchainEnv(values: values, home: tmp.path);
  }

  group('android-sdk precedence policy', () {
    test('1. explicit config wins and is reported as source', () async {
      final sdk = await makeSdk('cfg');
      final other = await makeSdk('env_sdk');
      final tc = AndroidToolchain(
        androidSdkPath: sdk,
        env: env(okaAndroidSdk: other),
      );
      final r = await tc.resolve(const ToolQuery('android-sdk'));
      expect(r.ok, isTrue);
      expect(r.tool!.path, sdk);
      expect(r.tool!.source.kind, ToolSourceKind.config);
    });

    test('1b. missing configured path fails without falling through',
        () async {
      final other = await makeSdk('env_sdk');
      final tc = AndroidToolchain(
        androidSdkPath: p.join(tmp.path, 'nope'),
        env: env(okaAndroidSdk: other),
      );
      await expectLater(
        tc.require(const ToolQuery('android-sdk')),
        throwsA(
          isA<ToolchainException>().having(
            (e) => e.problem,
            'problem',
            contains('not found at configured path'),
          ),
        ),
      );
    });

    test('2. OKA_ANDROID_SDK beats ANDROID_HOME and ANDROID_SDK_ROOT',
        () async {
      final oka = await makeSdk('oka_sdk');
      final home = await makeSdk('home_sdk');
      final root = await makeSdk('root_sdk');
      final tc = AndroidToolchain(
        env: env(
          okaAndroidSdk: oka,
          androidHome: home,
          androidSdkRoot: root,
        ),
      );
      final r = await tc.resolve(const ToolQuery('android-sdk'));
      expect(r.tool!.path, oka);
      expect(r.tool!.source.kind, ToolSourceKind.env);
    });

    test('3. ANDROID_HOME beats ANDROID_SDK_ROOT', () async {
      final home = await makeSdk('home_sdk');
      final root = await makeSdk('root_sdk');
      final tc = AndroidToolchain(
        env: env(androidHome: home, androidSdkRoot: root),
      );
      final r = await tc.resolve(const ToolQuery('android-sdk'));
      expect(r.tool!.path, home);
    });

    test('4. oka-managed root is skipped without build-tools/', () async {
      final managed = Directory(p.join(tmp.path, '.oka', 'android-sdk'))
        ..createSync(recursive: true);
      final home = await makeSdk('home_sdk');
      final tc = AndroidToolchain(
        env: env(androidHome: home),
      );
      final r = await tc.resolve(const ToolQuery('android-sdk'));
      expect(r.tool!.path, home);
      expect(Directory(managed.path).existsSync(), isTrue);
    });

    test('5. managed root with build-tools wins when no env is set',
        () async {
      await makeSdk('.oka/android-sdk');
      final tc = AndroidToolchain(env: env());
      final r = await tc.resolve(const ToolQuery('android-sdk'));
      expect(r.tool!.path, p.join(tmp.path, '.oka', 'android-sdk'));
      expect(r.tool!.source.kind, ToolSourceKind.managed);
    });

    test('6. common system path is the last resort', () async {
      final libSdk = await makeSdk('Library/Android/sdk');
      final tc = AndroidToolchain(env: env());
      final r = await tc.resolve(const ToolQuery('android-sdk'));
      expect(r.tool!.path, libSdk);
      expect(r.tool!.source.kind, ToolSourceKind.system);
    });

    test('failure lists tried candidates in order and names the fix',
        () async {
      final tc = AndroidToolchain(
        env: env(
          // Set but pointing at missing dirs: tried, then skipped.
          androidHome: p.join(tmp.path, 'missing_home'),
          androidSdkRoot: p.join(tmp.path, 'missing_root'),
        ),
      );
      try {
        await tc.require(const ToolQuery('android-sdk'));
        fail('expected ToolchainException');
      } on ToolchainException catch (e) {
        expect(e.problem, contains('Android SDK not found'));
        expect(e.fix, contains('oka get android-sdk'));
        // Ordered policy, not if-chain soup: env sources before system ones.
        final firstSystem =
            e.tried.indexWhere((final t) => t.kind == ToolSourceKind.system);
        final lastEnv =
            e.tried.lastIndexWhere((final t) => t.kind == ToolSourceKind.env);
        expect(lastEnv, lessThan(firstSystem));
        expect(e.tried.map((final t) => t.label), contains('ANDROID_HOME'));
        expect(e.tried.map((final t) => t.label), contains('ANDROID_SDK_ROOT'));
      }
    });
  });

  group('build-tools version selection (regression)', () {
    test('latest version dir wins (reverse sort)', () async {
      final sdk = await makeSdk('sdk', versions: ['34.0.0', '35.0.0']);
      final tc = AndroidToolchain(androidSdkPath: sdk, env: env());
      final r = await tc.resolve(const ToolQuery('aapt2'));
      expect(r.tool!.path, p.join(sdk, 'build-tools', '35.0.0', 'aapt2'));
      expect(r.tool!.version, '35.0.0');
    });

    test('falls through version dirs missing the binary', () async {
      final sdk = Directory(p.join(tmp.path, 'sdk'))..createSync(recursive: true);
      Directory(p.join(sdk.path, 'build-tools', '35.0.0'))
          .createSync(recursive: true);
      File(p.join(sdk.path, 'build-tools', '35.0.0', 'd8'))
          .writeAsStringSync('#!');
      Directory(p.join(sdk.path, 'build-tools', '33.0.0'))
          .createSync(recursive: true);
      File(p.join(sdk.path, 'build-tools', '33.0.0', 'd8'))
          .writeAsStringSync('#!');
      File(p.join(sdk.path, 'build-tools', '33.0.0', 'aapt2'))
          .writeAsStringSync('#!');
      final tc = AndroidToolchain(androidSdkPath: sdk.path, env: env());
      final r = await tc.resolve(const ToolQuery('aapt2'));
      expect(r.tool!.path, p.join(sdk.path, 'build-tools', '33.0.0', 'aapt2'));
    });
  });

  group('r8 (optional tool, jar fallback)', () {
    test('resolves lib/r8.jar inside build-tools when binary missing',
        () async {
      final sdk = await makeSdk('sdk', binaries: const []);
      File(p.join(sdk, 'build-tools', '34.0.0', 'lib', 'r8.jar'))
        ..createSync(recursive: true)
        ..writeAsStringSync('jar');
      final tc = AndroidToolchain(androidSdkPath: sdk, env: env());
      final r = await tc.resolve(const ToolQuery('r8'));
      expect(r.tool!.path, p.join(sdk, 'build-tools', '34.0.0', 'lib', 'r8.jar'));
    });

    test('cmdline-tools fallback; null (not throw) when absent', () async {
      final sdk = await makeSdk('sdk', binaries: const []);
      File(p.join(sdk, 'cmdline-tools', 'latest', 'lib', 'r8.jar'))
        ..createSync(recursive: true)
        ..writeAsStringSync('jar');
      final tc = AndroidToolchain(androidSdkPath: sdk, env: env());
      expect((await tc.resolve(const ToolQuery('r8'))).tool!.path,
          p.join(sdk, 'cmdline-tools', 'latest', 'lib', 'r8.jar'));

      final sdk2 = await makeSdk('sdk2', binaries: const []);
      final tc2 = AndroidToolchain(androidSdkPath: sdk2, env: env());
      expect((await tc2.resolve(const ToolQuery('r8'))).ok, isFalse);
    });
  });

  group('adb / javac / kotlinc', () {
    test('adb resolves under platform-tools', () async {
      final sdk = await makeSdk('sdk', platformTools: true);
      final tc = AndroidToolchain(androidSdkPath: sdk, env: env());
      final r = await tc.resolve(const ToolQuery('adb'));
      expect(r.tool!.path, p.join(sdk, 'platform-tools', 'adb'));
    });

    test('adb failure names the fix', () async {
      final sdk = await makeSdk('sdk');
      final tc = AndroidToolchain(androidSdkPath: sdk, env: env());
      try {
        await tc.require(const ToolQuery('adb'));
        fail('expected ToolchainException');
      } on ToolchainException catch (e) {
        expect(e.fix, contains('platform-tools'));
      }
    });

    test('javac: JAVA_HOME fallback with empty injected PATH', () async {
      final javaHome = Directory(p.join(tmp.path, 'jdk'))..createSync();
      Directory(p.join(javaHome.path, 'bin')).createSync();
      File(p.join(javaHome.path, 'bin', 'javac')).writeAsStringSync('#!');
      final tc = AndroidToolchain(
        env: env(javaHome: javaHome.path, path: tmp.path),
      );
      final r = await tc.resolve(const ToolQuery('javac'));
      expect(r.tool!.path, p.join(javaHome.path, 'bin', 'javac'));
      expect(r.tool!.source.kind, ToolSourceKind.env);
      expect(
        r.tried.first.label,
        'PATH (which javac)',
      );
    });

    test('kotlinc: KOTLIN_HOME is the last candidate', () async {
      final kotlinHome = Directory(p.join(tmp.path, 'kotlin-home'))
        ..createSync();
      Directory(p.join(kotlinHome.path, 'bin')).createSync();
      File(p.join(kotlinHome.path, 'bin', 'kotlinc')).writeAsStringSync('#!');
      final tc = AndroidToolchain(
        env: env(kotlinHome: kotlinHome.path, path: tmp.path),
      );
      final r = await tc.resolve(const ToolQuery('kotlinc'));
      expect(r.tool!.path, p.join(kotlinHome.path, 'bin', 'kotlinc'));
      expect(r.tool!.source.kind, ToolSourceKind.env);
    });

    test('kotlinc: managed ~/.oka/tools wins over PATH', () async {
      final managed = Directory(p.join(tmp.path, '.oka', 'tools', 'kotlin-2.1.0', 'bin'))
        ..createSync(recursive: true);
      File(p.join(managed.path, 'kotlinc')).writeAsStringSync('#!');
      final tc = AndroidToolchain(env: env(path: tmp.path));
      final r = await tc.resolve(const ToolQuery('kotlinc'));
      expect(
        r.tool!.path,
        p.join(tmp.path, '.oka', 'tools', 'kotlin-2.1.0', 'bin', 'kotlinc'),
      );
      expect(r.tool!.source.kind, ToolSourceKind.managed);
    });
  });

  group('policy as a printable value', () {
    test('describe() returns the ordered, typed candidate sources',
        () async {
      final sdk = await makeSdk('sdk');
      final tc = AndroidToolchain(androidSdkPath: sdk, env: env());
      final policy = tc.describe(const ToolQuery('android-sdk'));
      expect(policy.first.kind, ToolSourceKind.config);
      expect(policy, everyElement(isA<ToolSource>()));
      // Env sources come before system sources.
      final firstSystem =
          policy.indexWhere((final s) => s.kind == ToolSourceKind.system);
      final lastEnv =
          policy.lastIndexWhere((final s) => s.kind == ToolSourceKind.env);
      expect(lastEnv, lessThan(firstSystem));
    });

    test('doctor lines: resolved tool prints path + source; missing prints '
        'tried + fix', () async {
      final sdk = await makeSdk('sdk', versions: ['35.0.0']);
      final tc = ResolvedToolchain(androidSdkPath: sdk, env: env());
      final lines = await tc.describePolicyLines(tools: const [
        'android-sdk',
        'aapt2',
        'adb',
      ]);
      expect(
        lines.any((final l) => l.startsWith('✅ android-sdk: $sdk')),
        isTrue,
      );
      expect(
        lines.any((final l) =>
            l.contains('source:') &&
            l.contains('config androidSdkPath')),
        isTrue,
      );
      expect(
        lines.any((final l) => l.contains('aapt2') && l.contains('35.0.0')),
        isTrue,
      );
      expect(lines.where((final l) => l.startsWith('❌ adb: not found')),
          hasLength(1));
      expect(
        lines.any((final l) => l.contains('fix:') && l.contains('platform-tools')),
        isTrue,
      );
    });
  });
}
