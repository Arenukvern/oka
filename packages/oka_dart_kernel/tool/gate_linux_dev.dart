// Dart-owned Linux L0 dev gates — thin bootstrap; legs in lib/src/gate.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:oka_dart_kernel/src/gate/dev_gate_signals.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  var leg = 'all';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--leg' && i + 1 < args.length) {
      leg = args[++i];
    }
  }

  final scriptDir = p.dirname(Platform.script.toFilePath());
  final kernelRoot = p.normalize(p.join(scriptDir, '..'));
  final workspace = p.normalize(p.join(kernelRoot, '..', '..'));
  final useXvfb = Platform.environment['OKA_LINUX_DEV_GATE_USE_XVFB'] == '1';

  final gate = LinuxDevGate(workspace: workspace, useXvfb: useXvfb);
  DevGateSignalCoordinator(onSignal: gate.interruptCleanup).install();
  var failed = 0;

  if (leg == 'reload' || leg == 'all') {
    final flutter = Platform.environment['FLUTTER_BIN'] ?? 'flutter';
    final head = await _flutterHead(flutter);
    print(
      '== gate_run_dev_linux host: ${await _hostArch()} flutter=$head',
    );
    final code = await gate.runReloadLeg();
    if (code == 0) {
      print('gate: linux desktop dev session (reload + restart) — ALL PASS');
    } else {
      print('gate: linux desktop dev session — FAILED');
      failed = 1;
      if (leg == 'all') {
        print('gate: skipping assets leg — reload gate failed');
        print('gate: linux dev convergence L0 — FAILED');
        exit(1);
      }
    }
    if (leg == 'reload') exit(failed);
  }

  if (leg == 'assets' || leg == 'all') {
    final code = await gate.runAssetsLeg();
    if (code == 0) {
      print('gate: linux dev-session asset lane — ALL PASS');
    } else {
      print('gate: linux dev-session asset lane — FAILED');
      failed = 1;
    }
  }

  if (leg == 'all') {
    if (failed == 0) {
      print('gate: linux dev convergence L0 — ALL PASS');
    } else {
      print('gate: linux dev convergence L0 — FAILED');
    }
  }
  exit(failed);
}

Future<String> _hostArch() async {
  final r = await runBoundedProcess(
    'uname',
    ['-m'],
    timeout: const Duration(seconds: 10),
  );
  return r.exitCode == 0 ? r.stdout.trim() : 'unknown';
}

Future<String> _flutterHead(String flutterBin) async {
  final r = await runBoundedProcess(
    flutterBin,
    ['--version'],
    timeout: const Duration(seconds: 30),
  );
  if (r.exitCode != 0) return 'unknown';
  final first = r.stdout.split('\n').first.trim();
  final idx = first.indexOf(' • ');
  return idx == -1 ? first : first.substring(0, idx);
}
