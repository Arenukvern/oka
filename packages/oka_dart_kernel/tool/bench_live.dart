/// Kernel/live-stack benchmarks (`oka/kernel-benchmarks/v1`).
///
/// Hermetic: the subject is a throwaway three-file app in a temp dir; no
/// Flutter, no network. Measures the composition loop end to end:
///
/// - `packages_config`        merged checkout kernel-stack config
/// - `pipeline_full_jit/aot`  whole-program kernel compile (JIT dart vs the
///                            AOT pipeline exe — same bytes out)
/// - `pipeline_delta_jit/aot` per-unit delta compile
/// - `live_apply_vm`          full session apply on a running app: connect,
///                            baseline, patch, compile delta (AOT), apply
///                            via `_reloadKernel`, verify probes
/// - `patch_plan_x1000`       in-process eligibility planning (oka_update)
///
/// Machine JSON on stdout; humans read the event ladder on stderr.
/// Entry: `just bench-kernel` (or tool/benchmarks/kernel_benchmarks.sh).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_update/oka_update.dart';

const _sdkHash = '60a57cd42d'; // dart 3.13.2 checkout pin (see gates)

Future<ProcessResult> _run(
  String exe,
  List<String> args, {
  Map<String, String> env = const {},
  String? workingDirectory,
}) => Process.run(
  exe,
  args,
  workingDirectory: workingDirectory,
  environment: env,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

Future<void> _waitFor(
  File log,
  String pattern, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (log.existsSync() && log.readAsStringSync().contains(pattern)) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError('timed out waiting for "$pattern" in ${log.path}');
}

Future<(String, String)> _hermeticApp(Directory dir) async {
  final units = Directory('${dir.path}/lib/units')..createSync(recursive: true);
  File('${units.path}/feature.dart').writeAsStringSync('''
const String featureLabel = 'alpha-v1';

String feature() => 'alpha-v1';
''');
  File('${dir.path}/lib/main.dart').writeAsStringSync(r'''
import 'dart:async';

import 'units/feature.dart';

String status() => 'feature=${feature()} state=$boot';
final String boot = DateTime.now().microsecondsSinceEpoch.toString();

void main() {
  print('app: ' + status());
  Timer.periodic(const Duration(seconds: 1), (_) {});
}
''');
  File('${dir.path}/pubspec.yaml').writeAsStringSync(
    'name: bench_app\npublish_to: none\nenvironment:\n  sdk: ^3.12.0\n',
  );
  return ('${dir.path}/lib/main.dart', '${units.path}/feature.dart');
}

UnitDeltaCompiler _compiler({
  required String? exe,
  required String dartBin,
  required String packages,
  required String summary,
  required String sdkHash,
  required Directory deltaDir,
}) => (request) async {
  final out = '${deltaDir.path}/${request.unit}.delta.dill';
  final ProcessResult proc;
  if (exe != null) {
    proc = await _run(
      exe,
      ['--delta', request.patchedFiles.first, out],
      env: {'DART_SDK_SUMMARY': summary},
    );
  } else {
    proc = await _run(
      dartBin,
      [
        '-Dsdk_hash=$sdkHash',
        '--packages=$packages',
        'tool/gate_pipeline.dart',
        '--delta',
        request.patchedFiles.first,
        out,
      ],
      env: {'DART_SDK_SUMMARY': summary},
    );
  }
  if (proc.exitCode != 0) {
    throw StateError('delta compile failed: ${proc.stderr}');
  }
  return DeltaArtifact(path: out, bytes: File(out).lengthSync());
};

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final checkout =
      env['OKA_SDK_CHECKOUT'] ??
      '${Platform.environment['HOME']}/xs/dart-sdks/sdk-3.13.2';
  if (!File('$checkout/pkg/kernel/pubspec.yaml').existsSync()) {
    stderr.writeln(
      'bench: SDK checkout not usable at "$checkout" '
      '(need pkg/kernel, pkg/vm, pkg/front_end sources). Provision:\n'
      '  git clone --depth 1 -b <dart-version> '
      'https://github.com/dart-lang/sdk.git "$checkout"\n'
      'or point OKA_SDK_CHECKOUT at an existing dart-lang/sdk checkout.',
    );
    exitCode = 255;
    return;
  }
  final dartBin = env['OKA_BENCH_DART'] ?? Platform.resolvedExecutable;
  // The checkout's kernel stack and the VM that live-applies must be the
  // same SDK generation — a mismatch compiles fine and then dies mid-
  // reload ("Service has disappeared"). Name it before wasting a run.
  String? checkoutVersion;
  final versionFile = File('$checkout/tools/VERSION');
  if (versionFile.existsSync()) {
    final text = versionFile.readAsStringSync();
    String? part(final String name) =>
        RegExp('^$name (\\d+)', multiLine: true).firstMatch(text)?.group(1);
    final major = part('MAJOR');
    final minor = part('MINOR');
    final patch = part('PATCH');
    if (major != null && minor != null && patch != null) {
      checkoutVersion = '$major.$minor.$patch';
    }
  }
  final dartVersionOut = await Process.run(dartBin, ['--version']);
  final versionText = '${dartVersionOut.stdout}${dartVersionOut.stderr}';
  final runningDartVersion =
      RegExp(r'(\d+\.\d+\.\d+)').firstMatch(versionText)?.group(1) ?? 'unknown';
  if (runningDartVersion != checkoutVersion &&
      !runningDartVersion.startsWith('$checkoutVersion.')) {
    stderr.writeln(
      'bench: SDK mismatch — checkout $checkoutVersion vs running dart '
      '$runningDartVersion. The live-apply step pairs the checkout kernel stack '
      'with this VM; provision a matching checkout:\n'
      '  git clone --depth 1 -b $runningDartVersion '
      'https://github.com/dart-lang/sdk.git '
      '"\${HOME}/xs/dart-sdks/sdk-$runningDartVersion"\n'
      'and point OKA_SDK_CHECKOUT at it (or OKA_BENCH_DART at a VM of '
      'version $checkoutVersion).',
    );
    exitCode = 255;
    return;
  }
  final here = File.fromUri(Platform.script).parent.parent.path; // package dir
  final outDir = await Directory.systemTemp.createTemp('oka-bench-live');
  final results = <String, double>{};
  String? exe;

  Future<void> step(String name, Future<void> Function() body) async {
    stderr.writeln('bench: $name');
    final sw = Stopwatch()..start();
    await body();
    sw.stop();
    results[name] = sw.elapsedMicroseconds / Duration.microsecondsPerSecond;
    stderr.writeln('bench: $name = ${results[name]!.toStringAsFixed(3)}s');
  }

  // 0. merged config (the checkout kernel stack the pipeline runs under).
  late String packages;
  await step('packages_config', () async {
    final proc = await _run('bash', [
      'tool/pipeline_packages_config.sh',
      checkout,
      '3.13',
      outDir.path,
    ], workingDirectory: here);
    if (proc.exitCode != 0) {
      throw StateError('packages config failed: ${proc.stderr}');
    }
    packages = (proc.stdout as String).trim().split('\n').last;
  });

  // Hermetic app + summary + pipeline package config.
  final (entry, unitFile) = await _hermeticApp(outDir);
  final summaryPath = File(dartBin).parent.parent.path;
  final summary = '$summaryPath/lib/_internal/vm_platform_strong.dill';
  final appPackages = '${outDir.path}/app_package_config.json';
  File(appPackages).writeAsStringSync(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        {
          'name': 'bench_app',
          'rootUri': 'file://${outDir.path}',
          'packageUri': 'lib/',
          'languageVersion': '3.12',
        },
      ],
    }),
  );

  // 1. full compile: JIT vs AOT (same bytes).
  final jitFull = '${outDir.path}/full_jit.dill';
  await step('pipeline_full_jit', () async {
    final proc = await _run(
      dartBin,
      [
        '-Dsdk_hash=$_sdkHash',
        '--packages=$packages',
        'tool/gate_pipeline.dart',
        entry,
        jitFull,
      ],
      env: {'DART_SDK_SUMMARY': summary, 'DART_PACKAGES_CONFIG': appPackages},
    );
    if (proc.exitCode != 0) throw StateError('jit full failed: ${proc.stderr}');
  });

  await step('pipeline_exe_build', () async {
    final proc = await _run('bash', [
      'tool/build_pipeline_exe.sh',
      checkout,
      '3.13',
      '${outDir.path}/pipeline.exe',
    ], workingDirectory: here);
    if (proc.exitCode != 0) {
      throw StateError('exe build failed: ${proc.stderr}');
    }
    exe = '${outDir.path}/pipeline.exe';
  });

  final aotFull = '${outDir.path}/full_aot.dill';
  await step('pipeline_full_aot', () async {
    final proc = await _run(
      exe!,
      [entry, aotFull],
      env: {'DART_SDK_SUMMARY': summary, 'DART_PACKAGES_CONFIG': appPackages},
    );
    if (proc.exitCode != 0) throw StateError('aot full failed: ${proc.stderr}');
    bool sameBytes(List<int> a, List<int> b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    final same = sameBytes(
      await File(jitFull).readAsBytes(),
      await File(aotFull).readAsBytes(),
    );
    if (!same) {
      final a = await File(jitFull).length();
      final b = await File(aotFull).length();
      throw StateError(
        'AOT full dill differs from JIT (jit=$a bytes, aot=$b bytes)',
      );
    }
  });

  // 2. delta compile: JIT vs AOT.
  const editOld = "String feature() => 'alpha-v1';";
  const editNew = "String feature() => 'alpha-v2-live';";
  Future<void> compileDelta(String name, String out, {required bool aot}) =>
      step(name, () async {
        final compiler = _compiler(
          exe: aot ? exe : null,
          dartBin: dartBin,
          packages: packages,
          summary: summary,
          sdkHash: _sdkHash,
          deltaDir: outDir,
        );
        await compiler(
          DeltaRequest(
            revision: 'bench',
            unit: 'feature',
            root: outDir.path,
            patchedFiles: [unitFile],
          ),
        );
      });

  await compileDelta(
    'pipeline_delta_jit',
    '${outDir.path}/d_jit.dill',
    aot: false,
  );
  await compileDelta(
    'pipeline_delta_aot',
    '${outDir.path}/d_aot.dill',
    aot: true,
  );

  // 3. live session apply on a real running app (the composition loop).
  await step('live_apply_vm', () async {
    const port = 8231;
    final appLog = File('${outDir.path}/app.log');
    final app = await Process.start(
      dartBin,
      [
        '--enable-vm-service=$port/127.0.0.1',
        '--disable-service-auth-codes',
        entry,
      ],
      environment: {'DART_PACKAGES_CONFIG': appPackages},
    );
    final logSink = appLog.openWrite();
    unawaited(app.stdout.listen(logSink.add).asFuture<void>());
    unawaited(app.stderr.listen(logSink.add).asFuture<void>());
    try {
      await _waitFor(
        appLog,
        'VM service is listening',
        timeout: const Duration(seconds: 60),
      );
      final spec = LivePatchSpec(
        revision: 'bench-v2',
        unit: 'feature',
        patches: [PatchEdit(file: unitFile, find: editOld, replace: editNew)],
        targets: [
          const TargetSpec(
            kind: 'vm',
            id: 'bench-vm',
            ws: 'ws://127.0.0.1:$port/ws',
          ),
        ],
        probes: [
          const ProbeSpec(
            expression: 'feature()',
            library: 'main.dart',
            expect: 'alpha-v2-live',
          ),
          const ProbeSpec(expression: 'boot', library: 'main.dart', hold: true),
        ],
      );
      final session = LivePatchSession(
        spec: spec,
        root: outDir.path,
        compile: _compiler(
          exe: exe,
          dartBin: dartBin,
          packages: packages,
          summary: summary,
          sdkHash: _sdkHash,
          deltaDir: outDir,
        ),
      );
      final receipt = await session.run();
      stderr.writeln(receipt.describe());
      if (!receipt.ok) throw StateError('live apply failed');
    } finally {
      app.kill();
      await logSink.flush();
      await logSink.close();
    }
  });

  // 4. eligibility planning (in-process, oka_update).
  await step('patch_plan_x1000', () async {
    const units = {'alpha': <String, dynamic>{}, 'beta': <String, dynamic>{}};
    Map<String, dynamic> manifest(String rev) => {
      'revision': rev,
      'coreFingerprint': 'core-1',
      'units': {
        for (final e in units.entries)
          e.key: {
            'libraries': {
              'lib/${e.key}.dart': {'sha256': rev == 'r1' ? 'x' : 'y'},
            },
            'contractFingerprint': 'c-1',
          },
      },
    };
    final base = manifest('r1');
    final next = manifest('r2');
    for (var i = 0; i < 1000; i++) {
      final plan = planRevisions(base, next);
      if (!plan.patchable || plan.changedUnits.length != 2) {
        throw StateError('planner regression');
      }
    }
  });

  // Machine summary.
  final gitProc = await _run('git', [
    'rev-parse',
    '--short=8',
    'HEAD',
  ], workingDirectory: Directory.current.path);
  final dartVersion = (await _run(dartBin, [
    '--version',
  ])).stderr.toString().trim();
  final machine = {
    'schema': 'oka/kernel-benchmarks/v1',
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'results_seconds': results,
    'notes': {
      'pipeline_full_aot': 'byte-identical dill to pipeline_full_jit',
      'live_apply_vm':
          'connect + baseline + patch + AOT delta + '
          '_reloadKernel + probes, on a real dart VM',
    },
    'environment': {
      'oka_commit': (gitProc.stdout as String).trim(),
      'dart': dartVersion,
      'sdk_checkout': checkout,
      'os': Platform.operatingSystem,
      'note': 'machine-dependent; compare only against similar setups',
    },
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(machine));
  await outDir.delete(recursive: true);
}
