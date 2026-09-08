// ADR-0011 H1 — session manifest (`run_session.json`) / flag parity.
//
// Covers:
// * manifest round-trip (write → load → identical fields) + deterministic
//   encoding (sorted define keys, fixed field order);
// * forward-tolerant reads (unknown fields ignored) and fail-closed reads
//   (missing / corrupt / unknown-schema manifests throw with the fix);
// * `validateRunSession`: mismatch detection per field (target_file,
//   build_mode, dart_defines — including differing-keys rendering,
//   application_id), CLI↔manifest normalization parity
//   (`--dart-define` vs `--dart-define-from-file`);
// * flutter binary resolved from the recorded SDK path (never PATH);
// * `RecordRunSessionStep` golden file: the exact manifest the default
//   pipeline emits (golden-file test per the H1 exit criterion).
//
// No device, no real SDK — the flutter SDK is a fake tree with
// `bin/internal/engine.version`, the toolchain paths are injected.
import 'dart:convert';
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

RunSession _fixtureSession() => const RunSession(
      flutterSdkPath: '/sdks/flutter',
      engineRevision: 'f88005a259ba379c2c1156178aa1870936be7b7f',
      targetFile: 'lib/main.dart',
      buildMode: 'debug',
      dartDefines: {'STORE': 'googlePlay', 'FLAVOR': 'paid'},
      applicationId: 'dev.example.app',
      abis: ['arm64-v8a'],
      apkPath: '/proj/.oka_cache/build/debug/app-debug.apk',
      okaVersion: '0.6.0',
      recordedAt: '2026-09-07T12:00:00.000Z',
      trackWidgetCreation: true,
    );

BuildContext _ctx(final String projectPath) =>
    BuildContext(
      projectPath: projectPath,
      buildDir: p.join(projectPath, '.oka_cache', 'build', 'debug'),
      mode: BuildMode.debug,
      config: const OkaConfig({
        'name': 'fixture',
        'version': '1.0.0',
        'android': {
          'package_name': 'dev.example.app',
          'application_id': 'dev.example.app',
        },
        'flutter': {'entrypoint': 'lib/main.dart'},
      }),
      cacheDir: p.join(projectPath, '.oka_cache'),
      dartDefines: {'STORE': 'googlePlay'},
    );

void main() {
  group('normalization (CLI ↔ manifest parity)', () {
    test('normalizeDartDefines trims + sorts', () {
      final n = normalizeDartDefines(const {
        ' B ': '2',
        'A': ' 1 ',
      });
      expect(n, const {'A': '1', 'B': '2'});
      // Sorted insertion order is observable in the encoded JSON.
      expect(definesToLine(n), 'A=1, B=2');
    });

    test('mergeDartDefines: file entries + pairs, later CLI wins', () {
      final m = mergeDartDefines(
        pairs: const ['STORE=googlePlay', 'FLAG=x=1'],
        fileEntries: const {'STORE': 'sideload', 'FROM_FILE': 'yes'},
      );
      expect(m, const {'FROM_FILE': 'yes', 'FLAG': 'x=1', 'STORE': 'googlePlay'});
    });

    test('mergeDartDefines rejects KEY-less pairs loudly', () {
      expect(
        () => mergeDartDefines(pairs: const ['novalue']),
        throwsA(isA<FormatException>()),
      );
    });

    test('--dart-define and --dart-define-from-file normalize identically', () {
      final viaCli = mergeDartDefines(pairs: const ['STORE=googlePlay']);
      final viaFile = mergeDartDefines(
        fileEntries: const {'STORE': 'googlePlay'},
      );
      expect(viaCli, viaFile);
    });
  });

  group('RunSession round-trip + format', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_run_session_');
    });
    tearDown(() => tmp.delete(recursive: true));

    test('write → load → identical fields; schema + file name pinned', () async {
      final session = _fixtureSession();
      final path = p.join(tmp.path, runSessionFileName);
      await session.write(path);
      expect(runSessionFileName, 'run_session.json');
      expect(runSessionSchemaVersion, 1);

      final loaded = RunSession.load(path);
      expect(loaded.flutterSdkPath, session.flutterSdkPath);
      expect(loaded.engineRevision, session.engineRevision);
      expect(loaded.targetFile, session.targetFile);
      expect(loaded.buildMode, session.buildMode);
      expect(loaded.dartDefines, session.dartDefines);
      expect(loaded.applicationId, session.applicationId);
      expect(loaded.abis, session.abis);
      expect(loaded.apkPath, session.apkPath);
      expect(loaded.okaVersion, session.okaVersion);
      expect(loaded.recordedAt, session.recordedAt);
      expect(loaded.flavor, session.flavor);
      expect(loaded.trackWidgetCreation, session.trackWidgetCreation);
      expect(loaded.schema, runSessionSchemaVersion);
    });

    test('encoding is deterministic (sorted keys, fixed field order)',
        () async {
      final path = p.join(tmp.path, 'a.json');
      await _fixtureSession().write(path);
      final text = File(path).readAsStringSync();
      // Fixed field order: schema first, track_widget_creation last.
      expect(
        text.indexOf('"schema"') < text.indexOf('"flutter_sdk_path"'),
        isTrue,
      );
      expect(
        text.indexOf('"abis"') < text.indexOf('"track_widget_creation"'),
        isTrue,
      );
      // Dart-defines sorted inside the object.
      expect(
        text.indexOf('"FLAVOR"') < text.indexOf('"STORE"'),
        isTrue,
      );
      // Re-encoding is byte-identical (minus nothing — pure function).
      expect(_fixtureSession().encode(), text.trim());
    });

    test('forApk finds the manifest next to the APK (null when absent)',
        () async {
      final apk = p.join(tmp.path, 'app-debug.apk');
      File(apk).writeAsStringSync('apk');
      expect(RunSession.forApk(apk), isNull);
      await _fixtureSession().write(p.join(tmp.path, runSessionFileName));
      expect(RunSession.forApk(apk)?.flutterSdkPath, '/sdks/flutter');
    });

    test('unknown fields are tolerated (forward-compatible readers)',
        () async {
      final path = p.join(tmp.path, runSessionFileName);
      await _fixtureSession().write(path);
      final raw =
          (jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>)
            ..['future_field'] = {'x': 1};
      File(path).writeAsStringSync(jsonEncode(raw));
      expect(RunSession.load(path).targetFile, 'lib/main.dart');
    });

    test('missing manifest throws with the rebuild fix', () {
      expect(
        () => RunSession.load(p.join(tmp.path, 'missing.json')),
        throwsA(
          isA<RunSessionException>().having(
            (final e) => e.toString(),
            'message',
            contains('oka build apk --debug'),
          ),
        ),
      );
    });

    test('corrupt manifest throws fail-closed', () {
      final path = p.join(tmp.path, runSessionFileName);
      File(path).writeAsStringSync('{not json');
      expect(
        () => RunSession.load(path),
        throwsA(isA<RunSessionException>()),
      );
    });

    test('unknown schema refuses with an actionable error', () {
      final path = p.join(tmp.path, runSessionFileName);
      final raw = _fixtureSession().toJson()..['schema'] = 99;
      File(path).writeAsStringSync(jsonEncode(raw));
      expect(
        () => RunSession.load(path),
        throwsA(
          isA<RunSessionException>()
              .having((final e) => e.toString(), 'message', contains('99')),
        ),
      );
    });
  });

  group('validateRunSession (refuse, never warn-and-continue)', () {
    test('identical request passes', () {
      final v = validateRunSession(
        _fixtureSession(),
        const RunSessionRequest(
          targetFile: 'lib/main.dart',
          buildMode: 'debug',
          dartDefines: {'STORE': 'googlePlay', 'FLAVOR': 'paid'},
          applicationId: 'dev.example.app',
        ),
      );
      expect(v.ok, isTrue);
      expect(v.session, isNotNull);
    });

    test('unset request fields match anything', () {
      final v = validateRunSession(
        _fixtureSession(),
        const RunSessionRequest(),
      );
      expect(v.ok, isTrue);
    });

    test('target_file mismatch names the field + fix', () {
      final v = validateRunSession(
        _fixtureSession(),
        const RunSessionRequest(targetFile: 'lib/other.dart'),
      );
      expect(v.ok, isFalse);
      expect(v.mismatches.single.field, 'target_file');
      expect(v.mismatches.single.fix, contains('oka dev'));
    });

    test('build_mode mismatch: non-debug points at the debug-only scope cut',
        () {
      final v = validateRunSession(
        _fixtureSession(),
        const RunSessionRequest(buildMode: 'release'),
      );
      expect(v.mismatches.single.field, 'build_mode');
      expect(
        v.mismatches.single.fix.toLowerCase(),
        contains('debug-only'),
      );
    });

    test('dart_defines mismatch lists the differing keys', () {
      final v = validateRunSession(
        _fixtureSession(),
        const RunSessionRequest(
          dartDefines: {'STORE': 'sideload', 'EXTRA': '1'},
        ),
      );
      expect(v.ok, isFalse);
      final m = v.mismatches.single;
      expect(m.field, contains('dart_defines'));
      expect(m.field, contains('STORE'));
      expect(m.field, contains('EXTRA'));
      expect(m.recorded, contains('STORE=googlePlay'));
      expect(m.requested, contains('STORE=sideload'));
    });

    test('application_id mismatch detected', () {
      final v = validateRunSession(
        _fixtureSession(),
        const RunSessionRequest(applicationId: 'other.app'),
      );
      expect(v.mismatches.single.field, 'application_id');
    });

    test('formatSessionMismatches renders oka-branded, multi-field output',
        () {
      final v = validateRunSession(
        _fixtureSession(),
        const RunSessionRequest(
          targetFile: 'lib/other.dart',
          applicationId: 'other.app',
        ),
      );
      final text = formatSessionMismatches(v.mismatches);
      expect(text, contains('Session mismatch'));
      expect(text, contains('target_file'));
      expect(text, contains('application_id'));
      expect(text, contains('run_session.json'));
    });
  });

  group('flutter binary from the recorded SDK path (never PATH)', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_flutter_sdk_');
    });
    tearDown(() => tmp.delete(recursive: true));

    test('flutterBinaryForSdk points at <sdk>/bin/flutter', () {
      final r = flutterBinaryForSdk('/nonexistent/sdk');
      expect(r.path, p.join('/nonexistent', 'sdk', 'bin', 'flutter'));
      expect(r.exists, isFalse);
    });

    test('existing SDK resolves the binary and engine revision from file',
        () async {
      final sdk = Directory(p.join(tmp.path, 'flutter'));
      final f = File(
        p.join(sdk.path, 'bin', 'internal', 'engine.version'),
      );
      await f.create(recursive: true);
      await f.writeAsString('f88005a259ba379c2c1156178aa1870936be7b7f\n');
      // The binary itself must exist for [flutterBinaryForSdk] to report
      // `exists` (the engine.version file alone is not the binary).
      final bin = File(p.join(sdk.path, 'bin', 'flutter'));
      await bin.create(recursive: true);
      await bin.writeAsString('#!/bin/sh\n');
      final r = flutterBinaryForSdk(sdk.path);
      expect(r.exists, isTrue, reason: 'fake bin/flutter must exist for test');
      expect(
        await readEngineRevisionFromSdk(sdk.path),
        'f88005a259ba379c2c1156178aa1870936be7b7f',
      );
    });

    test('engine revision falls back to empty (never PATH flutter) when '
        'the SDK is empty', () async {
      // No engine.version file, no flutter binary → '' without touching PATH.
      expect(await readEngineRevisionFromSdk(tmp.path), '');
    });
  });

  group('RecordRunSessionStep (golden)', () {
    late Directory tmp;
    late String fakeSdk;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_record_session_');
      fakeSdk = p.join(tmp.path, 'fake_flutter');
      final f = File(p.join(fakeSdk, 'bin', 'internal', 'engine.version'));
      await f.create(recursive: true);
      await f.writeAsString('f88005a259ba379c2c1156178aa1870936be7b7f');
    });
    tearDown(() => tmp.delete(recursive: true));

    test('emits the exact documented manifest next to the APK', () async {
      final apkPath = p.join(
        tmp.path,
        '.oka_cache',
        'build',
        'debug',
        'app-debug.apk',
      );
      await File(apkPath).create(recursive: true);
      final ctx = _ctx(tmp.path);
      final state = PipelineState()
        ..apkPath = apkPath
        ..abis = ['arm64-v8a'];

      final result = await RecordRunSessionStep(
        flutterSdkPathOverride: fakeSdk,
      ).run(ctx, state);

      expect(result.ok, isTrue);
      final manifestPath = p.join(p.dirname(apkPath), runSessionFileName);
      expect(result.data[runSessionPath.id], manifestPath);

      final json =
          jsonDecode(File(manifestPath).readAsStringSync()) as Map<String, dynamic>;
      final recordedAt = json.remove('recorded_at') as String;
      // The only intentionally volatile field — must be ISO8601 UTC.
      expect(DateTime.tryParse(recordedAt)!.timeZoneOffset, Duration.zero);
      expect(json, <String, dynamic>{
        'schema': 1,
        'oka_version': '',
        'flutter_sdk_path': fakeSdk,
        'engine_revision': 'f88005a259ba379c2c1156178aa1870936be7b7f',
        'target_file': 'lib/main.dart',
        'build_mode': 'debug',
        'dart_defines': {'STORE': 'googlePlay'},
        'application_id': 'dev.example.app',
        'abis': ['arm64-v8a'],
        'apk_path': apkPath,
        'flavor': '',
        'track_widget_creation': true,
      });
    });

    test('fails loudly (never warn-and-continue) when the artifact is missing',
        () async {
      final state = PipelineState();
      final result = await RecordRunSessionStep(
        flutterSdkPathOverride: fakeSdk,
      ).run(_ctx(tmp.path), state);
      expect(result.ok, isFalse);
      expect(result.error, contains('package-and-sign'));
    });

    test('artifact contract: requires apk-path (validated before any tool '
        'runs)', () {
      final pipeline = Pipeline([RecordRunSessionStep()]);
      final error = pipeline.validate();
      expect(error, isNotNull);
      expect(error, contains('apk_path'));
    });
  });

  test('default pipelines record the session manifest (source contract)',
      () async {
    final text = await File(
      p.join(
        'packages',
        'oka_android',
        'lib',
        'src',
        'pipeline',
        'default_pipeline.dart',
      ),
    ).readAsString();
    expect(text, contains('RecordRunSessionStep'));
    // Both APK and AAB tails end with the recorder before the lint step.
    expect(
      RegExp('RecordRunSessionStep', multiLine: true).allMatches(text).length,
      2,
    );
  });

  group('checkDevSession (oka dev preflight — parse-and-delegate logic)', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('oka_dev_check_');
    });
    tearDown(() => tmp.delete(recursive: true));

    Future<void> seedBuild() async {
      final sdk = Directory(p.join(tmp.path, 'fake_flutter'));
      final ver = File(p.join(sdk.path, 'bin', 'internal', 'engine.version'));
      await ver.create(recursive: true);
      await ver.writeAsString('f88005a259ba379c2c1156178aa1870936be7b7f');
      final bin = File(p.join(sdk.path, 'bin', 'flutter'));
      await bin.create(recursive: true);
      await bin.writeAsString('#!/bin/sh\n');
      final apkDir = Directory(
        p.join(tmp.path, '.oka_cache', 'build', 'debug'),
      );
      await apkDir.create(recursive: true);
      await File(
        p.join(apkDir.path, 'app-debug.apk'),
      ).writeAsString('apk');
      final session = RunSession(
        flutterSdkPath: sdk.path,
        engineRevision: 'f88005a259ba379c2c1156178aa1870936be7b7f',
        targetFile: 'lib/main.dart',
        buildMode: 'debug',
        dartDefines: const {'STORE': 'googlePlay'},
        applicationId: 'dev.example.app',
        abis: const ['arm64-v8a'],
        apkPath: p.join(apkDir.path, 'app-debug.apk'),
      );
      await session.write(p.join(apkDir.path, runSessionFileName));
    }

    Future<DevSessionCheck> check({
      final String? targetFile,
      final List<String> pairs = const [],
      final String? defineFromFile,
    }) => checkDevSession(
          projectPath: tmp.path,
          targetFile: targetFile,
          dartDefinePairs: pairs,
          dartDefineFromFile: defineFromFile,
        );

    test('refuses when no APK was ever built', () async {
      final c = await check();
      expect(c.ok, isFalse);
      expect(c.refusal, contains('oka build apk --debug'));
    });

    test('refuses on a pre-manifest APK (rebuild fix)', () async {
      final apkDir = Directory(
        p.join(tmp.path, '.oka_cache', 'build', 'debug'),
      );
      await apkDir.create(recursive: true);
      await File(
        p.join(apkDir.path, 'app-debug.apk'),
      ).writeAsString('apk');
      final c = await check();
      expect(c.ok, isFalse);
      expect(c.refusal, contains('no session manifest'));
    });

    test('happy path: records resolve to the fake SDK + binary', () async {
      await seedBuild();
      final c = await check();
      expect(c.ok, isTrue);
      expect(c.session, isNotNull);
      // The flutter binary line points at the recorded SDK (never PATH).
      expect(
        c.lines.join('\n'),
        contains(p.join('fake_flutter', 'bin', 'flutter')),
      );
    });

    test('flag mismatch refuses, naming the differing field', () async {
      await seedBuild();
      final c = await check(targetFile: 'lib/other.dart');
      expect(c.ok, isFalse);
      expect(c.refusal, contains('target_file'));
    });

    test('define mismatch refuses (CLI pairs merged + normalized)',
        () async {
      await seedBuild();
      final c = await check(pairs: const ['STORE=sideload']);
      expect(c.ok, isFalse);
      expect(c.refusal, contains('dart_defines'));
    });

    test('matching defines (via define-from-file) pass', () async {
      await seedBuild();
      final f = File(p.join(tmp.path, 'defines.json'));
      await f.writeAsString('{"STORE": "googlePlay"}');
      final c = await check(defineFromFile: f.path);
      expect(c.ok, isTrue);
    });

    test('missing define-from-file refuses', () async {
      await seedBuild();
      final c = await check(defineFromFile: '/nope/missing.json');
      expect(c.ok, isFalse);
      expect(c.refusal, contains('dart-define-from-file'));
    });

    test('engine drift at the recorded path refuses (SDK upgraded)',
        () async {
      await seedBuild();
      final ver = File(
        p.join(
          tmp.path,
          'fake_flutter',
          'bin',
          'internal',
          'engine.version',
        ),
      );
      await ver.writeAsString('9999999999999999999999999999999999999999');
      final c = await check();
      expect(c.ok, isFalse);
      expect(c.refusal, contains('changed since the build'));
    });
  });
}
