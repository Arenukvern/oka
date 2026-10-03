/// The server's patch composition root — the SAME Dart value shape as the
/// app showcase's patch.dart. One API, one wire, one receipt; the only
/// difference is the target port.
///
/// The probes carry the whole contract of a server live patch:
/// - `greet()` flipped to the new revision (the patch took effect),
/// - `health()` held AND still returns 'ok' (the server never restarted),
/// - the uptime value inside `status()` kept growing (same process).
import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:oka_update/oka_update.dart';

final showcaseDir = File.fromUri(Platform.script).parent.path;
final appRoot = '$showcaseDir/app';

final serverPatch = LivePatchSpec(
  revision: 'server-v2',
  unit: 'greeter',
  patches: [
    PatchEdit(
      file: '$appRoot/lib/units/greeter.dart',
      find: "String greet() => 'hello-v1';",
      replace: "String greet() => 'hello-v2-live';",
    ),
  ],
  targets: [
    const TargetSpec.vmPort(8252, id: 'server-vm'),
  ],
  probes: [
    const ProbeSpec(
      expression: 'greet()',
      library: 'greeter.dart',
      expect: 'hello-v2-live',
    ),
    const ProbeSpec(
      expression: '1 + 1', // server still answering evaluation requests
      library: 'greeter.dart',
      hold: true,
    ),
  ],
);

Future<void> main() async {
  final toolchain = await resolvePipelineToolchain(
    okaDartKernelRoot: '../..',
    workDir: Directory('.build/toolchain'),
    appPackagesConfig: '.build/app_package_config.json',
  );

  final receipt = await runLivePatch(
    serverPatch,
    root: appRoot,
    compile: pipelineDeltaCompiler(toolchain),
    onEvent: (e) => print('live: ${e.why}'),
  );
  // ignore: avoid_print
  print(receipt.describe());
  exit(receipt.ok ? 0 : 1);
}
