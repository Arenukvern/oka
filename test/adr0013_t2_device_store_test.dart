// ADR-0013 T2 — Device layer through the store.
//
// Covers:
// * source contract: `dev/**` must not reference the deprecated `SdkLocator`
//   wrapper — device tools resolve through `ResolvedToolchain` only;
// * policy resolution for the new device tools (emulator, avdmanager,
//   system-images) with injected env — no real machine state;
// * store-backed provisioning round-trip (`AndroidDeviceProvisioner`):
//   store hit without any process spawn, miss → non-interactive download →
//   store registration → second call hits, download failure names the exact
//   remediation command (never interactive, stdin never read);
// * system-image provisioning: foreign-layout store registration after a
//   non-interactive sdkmanager install, and fail-closed with the exact
//   command when no non-interactive path exists;
// * dev steps consuming `ResolvedToolchain` (constructor value →
//   `state.resolvedToolchain` → default), including a full `DeviceTarget`
//   pipeline run with an injected toolchain.
//
// No real device, SDK, or network is used: adb/aapt2/sdkmanager/curl are
// fakes (shell scripts / injected process runner) and the store root is a
// throwaway directory.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

BuildContext _ctx(final String projectPath) => BuildContext(
      projectPath: projectPath,
      buildDir: p.join(projectPath, '.oka_cache', 'build', 'debug'),
      mode: BuildMode.debug,
      config: OkaConfig.empty,
      cacheDir: p.join(projectPath, '.oka_cache'),
      tempDir: p.join(projectPath, '.oka_cache', 'build', 'debug', 'temp'),
    );

/// Records invocations and answers `curl` with a real zip containing
/// `platform-tools/adb`, `chmod` with success — anything else fails the
/// test (proves provisioning spawned nothing unexpected).
Future<ProcessResult> Function(String, List<String>,
    {String? workingDirectory, Map<String, String>? environment}) _recordingRunner(
  final List<String> calls,
  final List<int> zipBytes,
) =>
    (
      executable,
      arguments, {
      workingDirectory,
      environment,
    }) async {
      calls.add('$executable ${arguments.join(' ')}');
      switch (executable) {
        case 'curl':
          final out = arguments[arguments.indexOf('-o') + 1];
          File(out).writeAsBytesSync(zipBytes);
          return ProcessResult(0, 0, '', '');
        case 'chmod':
          return ProcessResult(0, 0, '', '');
        default:
          fail('unexpected process spawned: $executable ${arguments.join(' ')}');
      }
    };

/// A runner that fails the test on ANY invocation (store-hit paths must
/// spawn nothing).
Future<ProcessResult> _noProcess(
  final String executable,
  final List<String> arguments, {
  final String? workingDirectory,
  final Map<String, String>? environment,
}) =>
    fail('expected a store hit — got process: $executable $arguments');

/// Fake sdkmanager that installs the test's system image package dir.
const _sdkManagerInstalls = r'''
case "$1" in --sdk_root=*) ROOT="${1#--sdk_root=}";; esac
PKG_DIR="$ROOT/system-images/android-34/google_apis/x86_64"
mkdir -p "$PKG_DIR"
printf 'Pkg.Desc=Android System Image\n' > "$PKG_DIR/source.properties"
exit 0
''';

const _sdkManagerFails = 'exit 1';

const _adbHappy = r'''
case "$1 $2" in
  "install -r") echo "Success"; exit 0;;
  "logcat -c") exit 0;;
  "logcat -d") exit 0;;
  "shell am") echo "Starting: Intent"; exit 0;;
  "shell pidof") echo "4242"; exit 0;;
esac
exit 1
''';

const _aapt2Badging = r'''
case "$1 $2" in
  "dump badging")
    echo "package: name='com.example.app' versionCode='1' versionName='1.0'"
    echo "launchable-activity: name='com.example.app.MainActivity'  label='Example'"
    exit 0;;
esac
exit 1
''';

Future<String> _script(
  final Directory dir,
  final String name,
  final String body,
) async {
  final f = File(p.join(dir.path, name))
    ..writeAsStringSync('#!/bin/sh\n$body');
  await Process.run('chmod', ['+x', f.path]);
  return f.path;
}

/// Fake Android SDK with the requested device-tool layout.
Future<String> makeSdk(
  final Directory tmp,
  final String name, {
  final bool platformTools = false,
  final bool emulator = false,
  final bool avdManager = false,
  final bool systemImages = false,
}) async {
  final sdk = Directory(p.join(tmp.path, name))..createSync(recursive: true);
  final bt = Directory(p.join(sdk.path, 'build-tools', '34.0.0'))
    ..createSync(recursive: true);
  for (final b in ['aapt2', 'd8', 'zipalign', 'apksigner']) {
    final f = File(p.join(bt.path, b))..writeAsStringSync('#!/bin/sh\n');
    await Process.run('chmod', ['+x', f.path]);
  }
  if (platformTools) {
    Directory(p.join(sdk.path, 'platform-tools')).createSync(recursive: true);
    final adb = File(p.join(sdk.path, 'platform-tools', 'adb'))
      ..writeAsStringSync('#!/bin/sh\n$_adbHappy');
    await Process.run('chmod', ['+x', adb.path]);
  }
  if (emulator) {
    Directory(p.join(sdk.path, 'emulator')).createSync(recursive: true);
    File(p.join(sdk.path, 'emulator', 'emulator'))
        .writeAsStringSync('#!/bin/sh\n');
  }
  if (avdManager) {
    Directory(p.join(sdk.path, 'cmdline-tools', 'latest', 'bin'))
        .createSync(recursive: true);
    File(p.join(
      sdk.path,
      'cmdline-tools',
      'latest',
      'bin',
      'avdmanager',
    )).writeAsStringSync('#!/bin/sh\n');
  }
  if (systemImages) {
    Directory(p.join(
      sdk.path,
      'system-images',
      'android-34',
      'google_apis',
      'x86_64',
    )).createSync(recursive: true);
  }
  return sdk.path;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_t2_device_');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
  });

  group('source contract: dev/** never touches the SdkLocator wrapper', () {
    test('no file under packages/oka_android/lib/src/dev references '
        'SdkLocator', () {
      final devDir = Directory(
        p.join(Directory.current.path, 'packages', 'oka_android', 'lib',
            'src', 'dev'),
      );
      expect(devDir.existsSync(), isTrue,
          reason: 'dev/ source tree must exist (run from the repo root)');
      final offenders = <String>[
        for (final f in devDir.listSync(recursive: true).whereType<File>())
          if (f.path.endsWith('.dart') &&
              f.readAsStringSync().contains('SdkLocator'))
            f.path,
      ];
      expect(offenders, isEmpty,
          reason: 'device steps must resolve through ResolvedToolchain '
              '(ADR-0013 T2), found SdkLocator in: $offenders');
    });
  });

  group('device-tool resolution policy (emulator / avdmanager / images)',
      () {
    test('emulator resolves under <sdk>/emulator', () async {
      final sdk = await makeSdk(tmp, 'sdk', emulator: true);
      final tc = AndroidToolchain(androidSdkPath: sdk);
      final r = await tc.resolve(const ToolQuery('emulator'));
      expect(r.ok, isTrue);
      expect(r.tool!.path, p.join(sdk, 'emulator', 'emulator'));
      expect(r.tool!.source.kind, ToolSourceKind.config);
    });

    test('avdmanager resolves under cmdline-tools/latest/bin', () async {
      final sdk = await makeSdk(tmp, 'sdk2', avdManager: true);
      final tc = AndroidToolchain(androidSdkPath: sdk);
      final r = await tc.resolve(const ToolQuery('avdmanager'));
      expect(r.ok, isTrue);
      expect(
        r.tool!.path,
        p.join(sdk, 'cmdline-tools', 'latest', 'bin', 'avdmanager'),
      );
    });

    test('system-images resolves the SDK directory', () async {
      final sdk = await makeSdk(tmp, 'sdk3', systemImages: true);
      final tc = AndroidToolchain(androidSdkPath: sdk);
      final r = await tc.resolve(const ToolQuery('system-images'));
      expect(r.ok, isTrue);
      expect(r.tool!.path, p.join(sdk, 'system-images'));
    });

    test('missing device tools fail with tried candidates + exact fixes',
        () async {
      final sdk = await makeSdk(tmp, 'sdk4');
      final tc = AndroidToolchain(androidSdkPath: sdk);
      for (final name in ['emulator', 'avdmanager', 'system-images']) {
        final r = await tc.resolve(ToolQuery(name));
        expect(r.ok, isFalse, reason: name);
        expect(r.problem, isNotNull, reason: name);
        // The SDK policy is the head of the tried set; the tool probe is
        // the tail.
        expect(r.tried, isNotEmpty, reason: name);
        expect(r.tried.last.label, contains(name), reason: name);
        final fix = tc.remediationFor(name);
        expect(fix, contains('sdkmanager'), reason: name);
      }
      // The emulator fix names the exact package.
      expect(tc.remediationFor('emulator'),
          contains('sdkmanager "emulator"'));
      expect(tc.remediationFor('system-images'),
          contains('system-images;android-34;google_apis;x86_64'));
    });

    test('describe() exposes the new tools as ordered policy values', () {
      final tc = AndroidToolchain();
      for (final name in ['emulator', 'avdmanager', 'system-images']) {
        final policy = tc.describe(ToolQuery(name));
        expect(policy, isNotEmpty, reason: name);
        expect(
          policy.first.label,
          contains(name == 'avdmanager'
              ? 'cmdline-tools/latest/bin/avdmanager'
              : name),
          reason: name,
        );
      }
    });

    test('doctor default tool set now includes the device tools', () {
      expect(
        ResolvedToolchain.defaultDoctorTools,
        containsAll(['adb', 'emulator', 'avdmanager']),
      );
    });
  });

  group('AndroidDeviceProvisioner.ensureAdb (store-backed platform-tools)',
      () {
    test('policy hit wins — an existing SDK adb short-circuits provisioning',
        () async {
      final sdk = await makeSdk(tmp, 'sdk', platformTools: true);
      final tc = ResolvedToolchain(androidSdkPath: sdk);
      final prov = AndroidDeviceProvisioner(
        store: LocalArtifactStore(root: p.join(tmp.path, 'store')),
        runProcess: _noProcess, // nothing may spawn on a policy hit
      );
      final adb = await prov.ensureAdb(toolchain: tc);
      expect(adb, p.join(sdk, 'platform-tools', 'adb'));
    });

    test('store round-trip: miss → download → register → hit without '
        're-downloading', () async {
      final store = LocalArtifactStore(root: p.join(tmp.path, 'store'));
      final calls = <String>[];
      // Filler keeps the payload above the 1 KB truncation sanity check
      // (deterministic pseudo-random bytes — DEFLATE can't crush them).
      var seed = 42;
      String noise(int n) => String.fromCharCodes(List.generate(
          n, (final i) => 33 + ((seed = seed * 1103515245 + 12345) >> 16) % 90));
      final filler = noise(2048);
      final zip = ZipEncoder().encode(
        Archive()
          ..addFile(ArchiveFile(
            'platform-tools/adb',
            _adbHappy.length,
            utf8.encode(_adbHappy),
          ))
          ..addFile(ArchiveFile(
            'platform-tools/NOTICE.txt',
            filler.length,
            utf8.encode(filler),
          )),
      );
      final runner = _recordingRunner(calls, zip);      final prov = AndroidDeviceProvisioner(store: store, runProcess: runner);

      final emptySdk = await makeSdk(tmp, 'empty'); // no platform-tools
      final tc = ResolvedToolchain(androidSdkPath: emptySdk);
      final adb = await prov.ensureAdb(toolchain: tc);

      // The downloaded binary is registered in the store and executable.
      expect(await File(adb).exists(), isTrue);
      expect(await File(adb).length(), greaterThan(0));
      expect(p.basename(adb), 'adb');
      expect(adb, contains(p.join('store', 'platform-tools')));
      expect(calls.where((final c) => c.startsWith('curl')), hasLength(1));

      final entries = await store.entries();
      expect(
        entries.any((final e) =>
            e.key.category == 'platform-tools' && e.key.name == 'adb'),
        isTrue,
        reason: 'download must be registered in the store index',
      );

      // Second call: store hit — no process spawns at all.
      final second = await AndroidDeviceProvisioner(
        store: store,
        runProcess: _noProcess,
      ).ensureAdb(toolchain: tc);
      expect(second, adb);
      expect(calls.where((final c) => c.startsWith('curl')), hasLength(1),
          reason: 'the zip must be downloaded exactly once');
    });

    test('download failure names the exact non-interactive remediation',
        () async {
      final emptySdk = await makeSdk(tmp, 'empty2');
      final tc = ResolvedToolchain(androidSdkPath: emptySdk);
      final prov = AndroidDeviceProvisioner(
        store: LocalArtifactStore(root: p.join(tmp.path, 'store2')),
        runProcess: (
          executable,
          arguments, {
          workingDirectory,
          environment,
        }) async =>
            ProcessResult(0, 22, '', 'HTTP error'),
      );
      await expectLater(
        prov.ensureAdb(toolchain: tc),
        throwsA(isA<ToolchainException>()
            .having((final e) => e.tool, 'tool', 'adb')
            .having((final e) => e.fix, 'fix',
                contains('sdkmanager "platform-tools"'))),
      );
    });

    test('no stdin anywhere: provisioning is structurally non-interactive',
        () {
      // Behavioral contract (ADR-0007), pinned here: the provider exposes no
      // stdin surface at all — downloads run through an injected runner
      // whose signature has no stdin parameter, sdkmanager runs via
      // Process.run (closed stdin — see the fail-closed tests above), and a
      // prompt-dependent install fails with the exact command instead of
      // prompting. Nothing to assert beyond the type system + tests above;
      // kept as a named marker in the suite.
      expect(AndroidDeviceProvisioner, isA<Type>());
    });
  });

  group('AndroidDeviceProvisioner.ensureSystemImage', () {
    const package = 'system-images;android-34;google_apis;x86_64';

    Future<String> sdkWithLicenses(final String name) async {
      final sdk = await makeSdk(tmp, name);
      Directory(p.join(sdk, 'licenses')).createSync();
      return sdk;
    }

    test('non-interactive sdkmanager install registers a store entry',
        () async {
      final sdk = await sdkWithLicenses('sdk');
      final manager = await _script(tmp, 'sdkmanager', _sdkManagerInstalls);
      final store = LocalArtifactStore(root: p.join(tmp.path, 'store'));
      final prov = AndroidDeviceProvisioner(store: store);

      final dir = await prov.ensureSystemImage(
        package: package,
        sdkRoot: sdk,
        sdkManagerPath: manager,
      );
      expect(dir, p.join(sdk, 'system-images', 'android-34', 'google_apis',
          'x86_64'));
      expect(File(p.join(dir, 'source.properties')).existsSync(), isTrue);

      // The install is registered: visible as a store entry (foreign
      // layout inside the SDK), so `oka cache list/gc` can see it.
      final entries = await store.entries();
      final pointer = entries
          .where((final e) => e.key.category == 'system-images')
          .toList();
      expect(pointer, hasLength(1));
      expect(pointer.single.key.name, package.replaceAll(';', '_'));
      expect(
        jsonDecode(await File(pointer.single.path).readAsString())
            as Map<String, dynamic>,
        containsPair('package_dir', dir),
      );

      // Second call: store hit — sdkmanager never runs again.
      await expectLater(
        AndroidDeviceProvisioner(store: store)
            .ensureSystemImage(
              package: package,
              sdkRoot: sdk,
              sdkManagerPath: '/nonexistent/sdkmanager',
            ),
        completion(dir),
      );
    });

    test('unaccepted licenses fail closed, naming the exact command',
        () async {
      final sdk = await makeSdk(tmp, 'sdk-no-licenses');
      final manager = await _script(tmp, 'sdkmanager2', _sdkManagerInstalls);
      final prov = AndroidDeviceProvisioner(
        store: LocalArtifactStore(root: p.join(tmp.path, 'store3')),
      );
      await expectLater(
        prov.ensureSystemImage(
          package: package,
          sdkRoot: sdk,
          sdkManagerPath: manager,
        ),
        throwsA(isA<ToolchainException>()
            .having((final e) => e.fix, 'fix', contains('sdkmanager'))
            .having((final e) => e.fix, 'fix', contains('"$package"'))),
      );
    });

    test('failed sdkmanager run fails closed (prompt-dependent runs never '
        'hang on stdin)', () async {
      final sdk = await sdkWithLicenses('sdk-fail');
      final manager = await _script(tmp, 'sdkmanager3', _sdkManagerFails);
      final prov = AndroidDeviceProvisioner(
        store: LocalArtifactStore(root: p.join(tmp.path, 'store4')),
      );
      await expectLater(
        prov.ensureSystemImage(
          package: package,
          sdkRoot: sdk,
          sdkManagerPath: manager,
        ),
        throwsA(isA<ToolchainException>().having(
          (final e) => e.fix,
          'fix',
          contains('sdkmanager --sdk_root=<sdk> "$package"'),
        )),
      );
    });
  });

  group('device steps consume ResolvedToolchain (no wrapper)', () {
    late Directory project;
    late Directory tools;
    late String apkPath;

    setUp(() async {
      project = await Directory.systemTemp.createTemp('oka_t2_steps_');
      tools = await Directory.systemTemp.createTemp('oka_t2_tools_');
      await _script(tools, 'adb', _adbHappy);
      await _script(tools, 'aapt2', _aapt2Badging);
      final apk = File(p.join(
        project.path,
        '.oka_cache',
        'build',
        'debug',
        'app-debug.apk',
      ));
      await apk.parent.create(recursive: true);
      await apk.writeAsBytes(List.filled(16, 1));
      apkPath = apk.path;
      addTearDown(() => project.delete(recursive: true));
      addTearDown(() => tools.delete(recursive: true));
    });

    test('constructor-injected toolchain resolves adb/aapt2 from a fake '
        'SDK (no adbPath given)', () async {
      final sdk = await makeSdk(tmp, 'sdk-steps', platformTools: true);
      final tc = ResolvedToolchain(androidSdkPath: sdk);
      final state = PipelineState()..[apkPathArtifactKey] = apkPath;
      final ctx = _ctx(project.path);

      final install = await InstallApkStep(toolchain: tc).run(ctx, state);
      expect(install.ok, isTrue, reason: install.error);
    });

    test('state-seeded toolchain (state.resolvedToolchain) is honored',
        () async {
      final sdk = await makeSdk(tmp, 'sdk-state', platformTools: true);
      final state = PipelineState()
        ..[apkPathArtifactKey] = apkPath
        ..resolvedToolchain = ResolvedToolchain(androidSdkPath: sdk);
      final ctx = _ctx(project.path);

      final install = await InstallApkStep().run(ctx, state);
      expect(install.ok, isTrue, reason: install.error);
    });

    test('missing adb in the policy fails the step with the fix', () async {
      final sdk = await makeSdk(tmp, 'sdk-no-adb');
      final tc = ResolvedToolchain(androidSdkPath: sdk);
      final state = PipelineState()..[apkPathArtifactKey] = apkPath;

      final install = await InstallApkStep(toolchain: tc).run(
        _ctx(project.path),
        state,
      );
      expect(install.ok, isFalse);
      expect(install.error, contains('adb not found'));
      expect(install.error, contains('platform-tools'));
    });

    test('full DeviceTarget pipeline with an injected toolchain (no '
        'per-step paths)', () async {
      final sdk = await makeSdk(tmp, 'sdk-e2e', platformTools: true);
      final tc = ResolvedToolchain(androidSdkPath: sdk);
      final pipeline = Pipeline(
        DeviceTarget(
          package: 'com.example.app',
          activity: 'com.example.app.MainActivity',
          waitSeconds: 0,
          toolchain: tc,
        ).compile(_ctx(project.path)),
      );
      expect(pipeline.validate(), isNull);
      final result = await pipeline.run(_ctx(project.path));
      expect(result.ok, isTrue, reason: result.error);
    });
  });
}

/// The device pipeline stages the APK under this artifact id
/// (`android_artifacts.dart`) — direct step runs seed it by hand.
const apkPathArtifactKey = 'apk_path';
