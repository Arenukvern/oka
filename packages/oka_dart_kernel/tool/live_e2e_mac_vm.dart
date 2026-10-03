/// Live-e2e leg 1 as a Dart driver (ADR-0036 Tier 1): bring-up, wait,
/// spec, patch, apply, verify, and teardown in one process — the gate
/// only asserts the exit code.
///
/// Target: stock dart VM on macOS running last_answer's headless driver
/// (`tool/oka_kernel_driver.dart --serve`), unit `doc_replica_store`,
/// `_reloadKernel` with a host path. Proves: probe flip + hold (no
/// restart) + receipt ok.
///
/// Env: LIVE_APP_ROOT, OKA_SDK_CHECKOUT. Exit 0 = leg PASS.
library;

import 'dart:convert';
import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:oka_update/oka_update.dart';

// ignore_for_file: avoid_print

final home = Platform.environment['HOME']!;
final appRoot = Platform.environment['LIVE_APP_ROOT'] ??
    '$home/xs/storage_problem/last_answer';
final port = 8184;

const storeFile = 'packages/headless_core/lib/src/doc_replica_store.dart';

Future<String> _dartVersion(String dartBin) async {
  final r = await Process.run(dartBin, const ['--version']);
  final out = '${r.stdout}${r.stderr}';
  return RegExp(r'\d+\.\d+\.\d+').firstMatch(out)!.group(0)!;
}

Future<void> main() async {
  final dartBin = File(Platform.resolvedExecutable).absolute.path;
  final ver = await _dartVersion(dartBin);
  final checkout = Platform.environment['OKA_SDK_CHECKOUT'] ??
      '$home/xs/dart-sdks/sdk-$ver';
  final toolchain = await resolvePipelineToolchain(
    checkout: checkout,
    okaDartKernelRoot:
        File.fromUri(Platform.script).parent.parent.path,
    workDir: Directory.systemTemp,
    appPackagesConfig: '$appRoot/.dart_tool/package_config.json',
  );

  final targetFile = File('$appRoot/$storeFile');
  final original = await targetFile.readAsString();
  Process? app;
  var failed = false;
  final log = <String>[];
  try {
    app = await Process.start(
      dartBin,
      [
        '--enable-vm-service=$port/127.0.0.1',
        '--disable-service-auth-codes',
        'tool/oka_kernel_driver.dart',
        '--serve',
      ],
      workingDirectory: appRoot,
    );
    app.stdout
        .transform(const Utf8Decoder())
        .transform(const LineSplitter())
        .listen(log.add);
    app.stderr
        .transform(const Utf8Decoder())
        .transform(const LineSplitter())
        .listen(log.add);

    final sw = Stopwatch()..start();
    while (!log.join('\n').contains('VM service is listening')) {
      if (sw.elapsed > const Duration(seconds: 120)) {
        throw StateError('app VM service never came up');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    print('mac-vm: target up (pid ${app.pid})');

    final receipt = await runLivePatch(
      LivePatchSpec(
        revision: 'rev-b',
        unit: 'doc_replica_store',
        patches: [
          PatchEdit(
            file: storeFile,
            find: "this.dir = 'doc_replicas',",
            replace: "this.dir = 'doc_replicas_live',",
          ),
        ],
        targets: [TargetSpec.vmPort(port, id: 'mac-vm')],
        probes: const [
          ProbeSpec(
            library: 'oka_kernel_driver.dart',
            expression: 'storeLabel()',
            expect: 'doc_replicas_live',
          ),
          ProbeSpec(
            library: 'oka_kernel_driver.dart',
            expression: 'identityHashCode(storeLabel)',
            hold: true,
          ),
        ],
      ),
      compile: pipelineDeltaCompiler(toolchain),
      root: appRoot,
      onEvent: (e) => print('live: ${e.why}'),
    );
    print(receipt.describe());
    if (!receipt.ok) throw StateError('live patch refused');
    print('mac-vm: live patch OK');
  } catch (e) {
    failed = true;
    print('mac-vm: FAILED — $e');
    final s = log.join('\n');
    print(s.length > 2000 ? s.substring(s.length - 2000) : s);
  } finally {
    await targetFile.writeAsString(original);
    app?.kill();
  }
  exit(failed ? 1 : 0);
}
