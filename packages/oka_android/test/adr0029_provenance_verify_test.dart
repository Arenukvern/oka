import 'dart:convert';
import 'dart:io';

import 'package:oka_android/src/android_artifacts.dart';
import 'package:oka_android/src/android_state.dart';
import 'package:oka_android/src/build/artifact_checks.dart';
import 'package:oka_android/src/build/provenance.dart';
import 'package:oka_android/src/build/startup_probe.dart';
import 'package:oka_android/src/dev/verify_target.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// ADR-0029: build provenance artifact (D1), package-time validation (D2),
/// failure signatures as data (D5), verification ladder (D3), and the
/// startup beacon (D7). Every fact here is one the 2026-09-27 incident
/// had to recover by hand.
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('oka_adr0029_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  BuildContext contextFor(final String name, {final BuildMode mode = BuildMode.release}) {
    final project = temp.createTempSync(name);
    final buildDir = p.join(project.path, '.oka_cache', 'build', mode.name);
    Directory(buildDir).createSync(recursive: true);
    return BuildContext(
      projectPath: project.path,
      buildDir: buildDir,
      mode: mode,
      config: OkaConfig.empty,
    );
  }

  /// A minimal ELF-looking blob carrying a Dart snapshot version hash the
  /// way gen_snapshot / the engine embed it.
  List<int> soWithVersion(final String hash, {final bool features = true}) =>
      latin1.encode(
        '<elf-padding>$hash${features ? 'product no-asan no-msan '
            'no-tsan no-shared_data no-code_comments no-dwarf_stack_traces '
            'arm64 android compressed-pointers' : ''}</elf-padding>',
      );

  group('provenance (D1)', () {
    test('record encodes + decodes round-trip', () {
      final record = ProvenanceRecord([
        const ProvenanceFact(factEngineVariant, '-release'),
        const ProvenanceFact(factAotBuildId, 'abc123'),
      ]);
      final decoded = ProvenanceRecord.decode(record.encode());
      expect(decoded.fact(factEngineVariant), '-release');
      expect(decoded.fact(factAotBuildId), 'abc123');
      expect(decoded.fact('missing'), isNull);
    });

    test('collectProvenance: later facts overwrite, order preserved', () {
      final record = collectProvenance([
        const ProvenanceFact('a', '1'),
        const ProvenanceFact('b', '2'),
        const ProvenanceFact('a', '3'),
      ], const []);
      expect(record.facts.map((final f) => f.key), ['a', 'b']);
      expect(record.fact('a'), '3');
    });

    test('stamp step writes oka-provenance.json into staged assets', () async {
      final ctx = contextFor('stamp');
      final state = PipelineState()
        ..abis = ['arm64-v8a']
        ..flutterAssetsDir = p.join(ctx.buildDir, 'assemble', 'flutter_assets')
        ..addProvenanceFact(const ProvenanceFact('my_plugin.variant', 'fast'));

      final result = await ProvenanceStampStep(
        contributors: [
          const _StaticContributor([ProvenanceFact('declared.fact', 'yes')]),
        ],
      ).run(ctx, state);

      expect(result.ok, isTrue, reason: result.error);
      final file = File(
        p.join(state.flutterAssetsDir!, 'oka-provenance.json'),
      );
      expect(file.existsSync(), isTrue);
      final decoded = ProvenanceRecord.decode(file.readAsStringSync());
      expect(decoded.fact('my_plugin.variant'), 'fast');
      expect(decoded.fact('declared.fact'), 'yes');
      expect(decoded.fact('build.mode'), 'release');
      expect(state.provenancePath, file.path);
    });
  });

  group('snapshot↔engine pairing check (D2)', () {
    const hash = '0451907c2eaa8467e848c0067bfe8ed4';

    test('matching pair passes; mismatched pair fails with the fix', () async {
      final ctx = contextFor('pair');
      final libDir = Directory(p.join(ctx.buildDir, 'lib', 'arm64-v8a'))
        ..createSync(recursive: true);
      final libapp = File(p.join(libDir.path, 'libapp.so'))
        ..writeAsBytesSync(soWithVersion(hash));
      final libflutter = File(p.join(libDir.path, 'libflutter.so'))
        ..writeAsBytesSync(soWithVersion(hash));
      final state = PipelineState()
        ..abis = ['arm64-v8a']
        ..libflutterByAbi = {'arm64-v8a': libflutter.path}
        ..libappByAbi = {'arm64-v8a': libapp.path};

      final ok = await const SnapshotEnginePairingCheck().check(
        ArtifactCheckContext(ctx, state),
      );
      expect(ok.passed, isTrue, reason: ok.detail);

      final other = File(p.join(libDir.path, 'other.so'))
        ..writeAsBytesSync(soWithVersion('ffffffffffffffffffffffffffffffff'));
      other.deleteSync();
      File(p.join(libDir.path, 'libapp_bad.so'))
          .writeAsBytesSync(soWithVersion('eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'));
      state.libappByAbi = {'arm64-v8a': p.join(libDir.path, 'libapp_bad.so')};
      final bad = await const SnapshotEnginePairingCheck()
          .check(ArtifactCheckContext(ctx, state));
      expect(bad.passed, isFalse);
      expect(bad.detail, contains('Rebuild the AOT'));
    });

    test('debug builds without AOT skip the pairing check', () async {
      final ctx = contextFor('pair_debug', mode: BuildMode.debug);
      final state = PipelineState()..abis = ['arm64-v8a'];
      final verdict = await const SnapshotEnginePairingCheck()
          .check(ArtifactCheckContext(ctx, state));
      expect(verdict.passed, isTrue);
      expect(verdict.detail, contains('no staged AOT'));
    });

    test('engine variant vs mode: debug engine in release fails loudly',
        () async {
      final ctx = contextFor('variant');
      final state = PipelineState()
        ..abis = ['arm64-v8a']
        ..addProvenanceFact(const ProvenanceFact(factEngineVariant, ''));

      final verdict = await const EngineVariantMatchesModeCheck().check(
        ArtifactCheckContext(ctx, state),
      );
      expect(verdict.passed, isFalse);
      expect(verdict.detail, contains("expected '-release'"));
    });

    test('ValidateArtifactStep fails the build on a failing check',
        () async {
      final ctx = contextFor('validate');
      final state = PipelineState()
        ..abis = ['arm64-v8a']
        ..flutterAssetsDir = p.join(ctx.buildDir, 'assemble', 'flutter_assets')
        ..addProvenanceFact(const ProvenanceFact(factEngineVariant, ''));

      // Debug engine variant + no AOT in a release build: the variant check
      // fails, completeness fails (missing release facts).
      final result = await ValidateArtifactStep().run(ctx, state);
      expect(result.ok, isFalse);
      expect(result.error, contains('artifact validation failed'));
    });
  });

  group('failure signatures (D5)', () {
    test('scan reports matched signatures with cause + fix', () {
      const log = '''
09-27 12:31:25.302 E flutter : [ERROR:flutter/runtime/dart_vm_data.cc(20)] VM snapshot invalid and could not be inferred from settings.
09-27 12:31:25.308 F libc : Fatal signal 11 (SIGSEGV)
''';
      final matches = scanFailureSignatures(log);
      final ids = matches.map((final m) => m.signature.id).toSet();
      expect(ids, containsAll(['vm-snapshot-invalid', 'fatal-signal']));
      final vm = matches.firstWhere(
        (final m) => m.signature.id == 'vm-snapshot-invalid',
      );
      expect(vm.line, contains('dart_vm_data.cc'));
      expect(vm.signature.fix, contains('pub get'));
      expect(vm.signature.evidence, isNotEmpty);
    });

    test('project extras compose on top of the builtin table', () {
      const mine = FailureSignature(
        id: 'backend-cold',
        needle: 'ECONNREFUSED my-backend',
        cause: 'backend down',
        fix: 'start the backend',
      );
      final matches = scanFailureSignatures(
        'error: ECONNREFUSED my-backend:9911',
        signatures: [...builtinFailureSignatures, mine],
      );
      expect(matches, hasLength(1));
      expect(matches.single.signature.id, 'backend-cold');
    });
  });

  group('verification ladder (D3)', () {
    test('device health: wedged systemui → inconclusive, never silent', () {
      final wedged = evaluateDeviceHealth(
        bootCompleted: '1',
        loadAvg1: 1.2,
        anrInFocus: true,
      );
      expect(wedged.status, RungStatus.inconclusiveDevice);
      expect(wedged.detail, contains('ANR'));

      final overloaded = evaluateDeviceHealth(
        bootCompleted: '1',
        loadAvg1: 51.6,
        anrInFocus: false,
      );
      expect(overloaded.status, RungStatus.inconclusiveDevice);

      final healthy = evaluateDeviceHealth(
        bootCompleted: '1',
        loadAvg1: 2.5,
        anrInFocus: false,
      );
      expect(healthy.status, RungStatus.passed);
    });

    test('first-frame parser reads dumpsys output', () {
      expect(
        parseRenderedFrames('Total frames rendered: 0\nJanky frames: 0'),
        0,
      );
      expect(
        parseRenderedFrames('Total frames rendered: 42'),
        42,
      );
    });

    test('rung steps record verdicts via an injected adb', () async {
      final ctx = contextFor('rungs');
      final state = PipelineState()
        ..abis = ['arm64-v8a']
        ..['device_package'] = 'com.example.app';
      final invocations = <List<String>>[];
      Future<ProcessResult> fakeAdb(
        final String adb,
        final List<String> args,
      ) async {
        invocations.add(args);
        final joined = args.join(' ');
        if (joined.contains('loadavg')) {
          return ProcessResult(0, 0, '1.2 1.0 0.9 1/100 123', '');
        }
        if (joined.contains('getprop')) {
          return ProcessResult(0, 0, '1\n', '');
        }
        if (joined.contains('dumpsys window')) {
          return ProcessResult(0, 0, 'mCurrentFocus=Window{app}', '');
        }
        if (joined.contains('pidof')) {
          return ProcessResult(0, 0, '4242', '');
        }
        if (joined.contains('gfxinfo')) {
          return ProcessResult(0, 0, 'Total frames rendered: 7', '');
        }
        if (joined.contains('logcat')) {
          return ProcessResult(0, 0, '[oka-beacon] main entered', '');
        }
        return ProcessResult(0, 0, '', '');
      }

      final health = DeviceHealthRungStep(
        adbPath: '/fake/adb',
        runAdb: fakeAdb,
      );
      expect(health.requires, contains(apkPath));
      final healthResult = await health.run(ctx, state);
      expect(healthResult.ok, isTrue);
      expect(
        RungVerdict.fromJson(
          jsonDecode(state.verificationVerdicts.last) as Map<String, dynamic>,
        ).status,
        RungStatus.passed,
      );

      final alive = ProcessAliveRungStep(
        adbPath: '/fake/adb',
        runAdb: fakeAdb,
        waitSeconds: 0,
      );
      await alive.run(ctx, state);
      final firstFrame = FirstFrameRungStep(
        adbPath: '/fake/adb',
        runAdb: fakeAdb,
        pollSeconds: 0,
      );
      await firstFrame.run(ctx, state);
      final beacon = DartMainBeaconRungStep(
        adbPath: '/fake/adb',
        runAdb: fakeAdb,
        expectBeacon: true,
      );
      await beacon.run(ctx, state);

      final verdicts = state.verificationVerdicts
          .map(
            (final line) =>
                RungVerdict.fromJson(jsonDecode(line) as Map<String, dynamic>),
          )
          .toList();
      expect(verdicts, hasLength(4));
      expect(verdicts.map((final v) => v.status), everyElement(RungStatus.passed));
      expect(
        verdicts.firstWhere((final v) => v.rung == 'dart-main').detail,
        contains('main entered'),
      );
      expect(invocations, isNotEmpty);
    });

    test('report step: failed rung fails; all-pass succeeds', () async {
      final ctx = contextFor('report');
      final failing = PipelineState()
        ..addVerificationVerdict(
          const RungVerdict(
            'snapshot-pairing',
            RungStatus.failed,
            detail: 'no shared snapshot version',
          ).encodeLine(),
        );
      final failResult = await VerificationReportStep().run(ctx, failing);
      expect(failResult.ok, isFalse);
      expect(failResult.error, contains('snapshot-pairing'));

      final passing = PipelineState()
        ..addVerificationVerdict(
          const RungVerdict(
            'device-health',
            RungStatus.passed,
          ).encodeLine(),
        );
      final okResult = await VerificationReportStep().run(ctx, passing);
      expect(okResult.ok, isTrue);

      final inconclusive = PipelineState()
        ..addVerificationVerdict(
          const RungVerdict(
            'device-health',
            RungStatus.inconclusiveDevice,
            detail: 'ANR dialog in focus',
          ).encodeLine(),
        );
      final incResult = await VerificationReportStep().run(ctx, inconclusive);
      expect(incResult.ok, isFalse);
      expect(incResult.error, contains('INCONCLUSIVE'));
    });
  });

  group('startup beacon (D7)', () {
    test('detects sync and async main shapes', () {
      expect(
        detectMainShape('void main() { runApp(App()); }'),
        (isAsync: false, takesArgs: false),
      );
      expect(
        detectMainShape(
          'Future<void> main(final List<String> args) async {}',
        ),
        (isAsync: true, takesArgs: true),
      );
      expect(
        detectMainShape('Future<void> main() async {}'),
        (isAsync: true, takesArgs: false),
      );
    });

    test('refuses to guess when no main declaration exists', () {
      expect(
        () => detectMainShape('void notMain() {}'),
        throwsFormatException,
      );
    });

    test('generated wrapper is deterministic and carries the beacon', () {
      final ctx = contextFor('beacon');
      File(p.join(ctx.projectPath, 'lib', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import 'package:flutter/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const App());
}
''');
      final first = generateStartupBeaconEntrypoint(
        projectPath: ctx.projectPath,
        entrypoint: 'lib/main.dart',
        buildDir: ctx.buildDir,
      );
      final second = generateStartupBeaconEntrypoint(
        projectPath: ctx.projectPath,
        entrypoint: 'lib/main.dart',
        buildDir: ctx.buildDir,
      );
      expect(first, second);
      final content = File(first).readAsStringSync();
      expect(content, contains(startupBeaconEnteredNeedle));
      expect(content, contains(startupBeaconReturnedNeedle));
      expect(content, contains(r'await $app.main();'));
      expect(File(first).existsSync(), isTrue);
    });
  });

  group('VerifyTarget composition', () {
    test('compiles the full ladder with the report last', () {
      final ctx = contextFor('target');
      final steps = const VerifyTarget(startupProbe: true).compile(ctx);
      final names = steps.map((final s) => s.name).toList();
      expect(names.first, 'resolve-device-apk');
      expect(names, contains('artifact-provenance-rung'));
      expect(names, contains('snapshot-pairing-rung'));
      expect(names, contains('device-health-rung'));
      expect(names, contains('process-alive-rung'));
      expect(names, contains('dart-main-rung'));
      expect(names, contains('first-frame-rung'));
      expect(names.last, 'verification-report');
    });

    test('custom rungs append before the report (third-party extension)',
        () {
      final ctx = contextFor('target-custom');
      final steps = VerifyTarget(rungs: [_CountingRung()]).compile(ctx);
      expect(steps[steps.length - 2], isA<_CountingRung>());
      expect(steps.last.name, 'verification-report');
    });

    test('rungs provide the verdicts artifact the report requires', () {
      expect(
        ArtifactProvenanceRungStep().provides,
        contains(verificationVerdicts),
      );
      expect(
        VerificationReportStep().requires,
        contains(verificationVerdicts),
      );
    });
  });
}

class _StaticContributor implements ProvenanceContributor {
  // ignore: avoid_constructor_with_non_const_args
  const _StaticContributor(this.facts);
  final List<ProvenanceFact> facts;

  @override
  List<ProvenanceFact> provenanceFacts(
    final BuildContext ctx,
    final PipelineState state,
  ) =>
      facts;
}

class _CountingRung extends RungStep {
  @override
  String get name => 'counting-rung';

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    record(
      state,
      const RungVerdict('counting', RungStatus.passed, detail: '42'),
    );
    return StepResult.success();
  }
}
