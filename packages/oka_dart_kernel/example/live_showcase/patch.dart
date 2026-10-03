/// The showcase's patch composition root — the whole live patch as one
/// Dart value, per oka's "everything is Dart" posture (ADR-0030: updates
/// are typed operations composed like builds, not config files).
///
/// Run: `./run.sh` (provisions the checkout toolchain once, starts the app,
/// then runs this file). What it does:
///
/// 1. resolves the kernel toolchain for the RUNNING dart (pinned checkout,
///    merged package config, AOT pipeline exe — cached under ~/.oka),
/// 2. applies the composed patch to the app running on :8242,
/// 3. prints the receipt: `feature()` flipped alpha-v1 -> alpha-v2-live and
///    `bootStamp` held (the process was never restarted).
import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:oka_update/oka_update.dart';

/// This file lives in example/live_showcase/; the app is ./app.
final showcaseDir = File.fromUri(Platform.script).parent.path;
final appRoot = '$showcaseDir/app';

/// The composed patch: unit, edit, target wire, probes. Every part is a
/// typed value — compose more (targets, probes, patches) as needed.
final showcasePatch = LivePatchSpec(
  revision: 'showcase-v2',
  unit: 'feature',
  patches: [
    PatchEdit(
      file: '$appRoot/lib/units/feature.dart',
      find: "String feature() => 'alpha-v1';",
      replace: "String feature() => 'alpha-v2-live';",
    ),
  ],
  targets: [
    const TargetSpec.vmPort(8242, id: 'showcase-vm'),
  ],
  probes: [
    const ProbeSpec(
      expression: 'status()',
      library: 'main.dart',
      expect: 'alpha-v2-live',
    ),
    const ProbeSpec(
      expression: 'bootStamp',
      library: 'main.dart',
      hold: true,
    ),
  ],
);

Future<void> main() async {
  final toolchain = await resolvePipelineToolchain(
    okaDartKernelRoot: '../..',
    workDir: Directory('.build/toolchain'),
    // The app runs under this config; the delta must be compiled with the
    // same one (URI coherence — see README).
    appPackagesConfig: '.build/app_package_config.json',
  );
  // ignore: avoid_print
  print('toolchain: aot=${toolchain.exe != null} hash=${toolchain.sdkHash}');

  final receipt = await runLivePatch(
    showcasePatch,
    root: showcaseDir,
    compile: pipelineDeltaCompiler(toolchain),
    onEvent: (e) => print('live: ${e.why}'),
  );
  // ignore: avoid_print
  print(receipt.describe());
  exit(receipt.ok ? 0 : 1);
}
