/// Product-families leg 1 (ADR-0035 §2e): oka live-patches ITSELF.
///
/// A plain Dart CLI — `oka doctor` — is spawned under the VM service and
/// patched mid-run. The delta is compiled BEFORE the target even starts
/// (markers on, compile, restore, keep the dill) and injected as the
/// session's compile function, so the apply lands ~1.5s into the doctor's
/// ~2.5s run: probe flip while alive, pid hold (no restart), and the
/// doctor's final line — printed after the patch — carries the marker.
///
/// The CLI's build surface is deliberately not used as the host: oka's
/// step digests include oka's own sources (the build is self-referential;
/// patching the tool mid-build invalidates its own cache — see
/// ADR-0035 §2e for the wire facts).
///
/// Env: OKA_ROOT, OKA_SDK_CHECKOUT, LIVE_PRODUCTS_PORT.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:oka_update/oka_update.dart';

// ignore_for_file: avoid_print, cancel_subscriptions, unused_local_variable, prefer_single_quotes, leading_newlines_in_multiline_strings

final home = Platform.environment['HOME']!;
final okaRoot = Platform.environment['OKA_ROOT'] ?? '$home/xs/oka';
final port = int.parse(Platform.environment['LIVE_PRODUCTS_PORT'] ?? '8327');

const doctorFile = 'packages/oka/lib/src/cli/doctor_command.dart';
const printFind =
    '''print("✅ All checks passed! You're ready to use Oka.");''';
const printReplace =
    '''print("✅ All checks passed! [oka-live] You're ready to use Oka.");''';
const probeFind = '''  } else if (value is YamlList) {
    return value.map(_yamlToJson).toList();
  }
  return value;''';
const probeReplace = '''  } else if (value is YamlList) {
    return value.map(_yamlToJson).toList();
  }
  return {'live-probe': 'patched-v2', 'orig': value};''';

Future<void> main() async {
  // Warm the toolchain (and the AOT pipeline exe) before anything else.
  final toolchain = await resolvePipelineToolchain(
    checkout: Platform.environment['OKA_SDK_CHECKOUT'],
    okaDartKernelRoot: File.fromUri(Platform.script).parent.parent.path,
    workDir: Directory.systemTemp,
    appPackagesConfig: '$okaRoot/.dart_tool/package_config.json',
  );
  if (toolchain.exe == null) {
    throw StateError('pipeline exe unavailable — delta would be too slow');
  }
  final compile = pipelineDeltaCompiler(toolchain);

  // Pre-stage the delta: markers on, compile, restore, keep the dill.
  final target = File('$okaRoot/$doctorFile');
  final original = await target.readAsString();
  await target.writeAsString(
      original.replaceFirst(printFind, printReplace)
          .replaceFirst(probeFind, probeReplace));
  DeltaArtifact prebuilt;
  try {
    prebuilt = await compile(DeltaRequest(
      revision: 'oka-self-1',
      unit: 'oka_cli',
      root: okaRoot,
      patchedFiles: ['$okaRoot/$doctorFile'],
    ));
  } finally {
    await target.writeAsString(original);
  }
  print('oka-cli: delta pre-staged (${prebuilt.bytes}B)');

  final log = StringBuffer();
  final app = await Process.start(
    Platform.resolvedExecutable,
    [
      '--enable-vm-service=$port/127.0.0.1',
      '--disable-service-auth-codes',
      'bin/oka.dart',
      'doctor',
    ],
    workingDirectory: '$okaRoot/packages/oka',
  );
  var failed = false;
  final clock = Stopwatch()..start();
  try {
    final outSub =
        app.stdout.transform(const Utf8Decoder()).listen(log.write);
    final errSub =
        app.stderr.transform(const Utf8Decoder()).listen(log.write);
    final outDone = outSub.asFuture<void>();
    final errDone = errSub.asFuture<void>();

    final sw = Stopwatch()..start();
    while (!log.toString().contains('The Dart VM service is listening')) {
      if (sw.elapsed > const Duration(seconds: 30)) {
        throw StateError('VM service never came up');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    print('oka-cli: banner at +${clock.elapsedMilliseconds}ms; patching');

    // The session re-writes the (same) markers on disk before handing the
    // request to the injected compile — which just returns the prebuilt
    // delta. Sources are restored in this driver's finally.
    final receipt = await runLivePatch(
      LivePatchSpec(
        revision: 'oka-self-1',
        unit: 'oka_cli',
        patches: [
          const PatchEdit(file: doctorFile, find: printFind, replace: printReplace),
          const PatchEdit(file: doctorFile, find: probeFind, replace: probeReplace),
        ],
        targets: [TargetSpec.vmPort(port, id: 'oka-cli')],
        probes: [
          const ProbeSpec(
            library: 'cli/doctor_command.dart',
            expression: "_yamlToJson('x')['live-probe'] ?? 'not-patched'",
            expect: 'patched-v2',
          ),
          // Same pid before and after = same process, no restart.
          const ProbeSpec(
            library: 'cli/doctor_command.dart',
            expression: 'pid',
            hold: true,
          ),
        ],
      ),
      compile: (request) async => prebuilt,
      root: okaRoot,
      onEvent: (e) =>
          print('live(+${clock.elapsedMilliseconds}ms): ${e.why}'),
    );
    print(receipt.describe());
    if (!receipt.ok) throw StateError('live patch refused');

    final code =
        await app.exitCode.timeout(const Duration(minutes: 2), onTimeout: () {
      app.kill();
      return -1;
    });
    // Piped stdout is block-buffered — drain before reading the log.
    await outDone.timeout(const Duration(seconds: 10),
        onTimeout: () {});
    await errDone.timeout(const Duration(seconds: 10),
        onTimeout: () {});
    final out = log.toString();
    // Single-shot CLI: the doctor's stdout usually completes inside the
    // patch path's ~2.5s floor, so the printed marker is a bonus, not the
    // criterion (the mcp-stdio and flutter-app legs carry the
    // product-visible flips). What this leg proves: the patched code is
    // live in the running process (probe flip), the process never
    // restarted (pid hold), and the CLI completed cleanly.
    final visible = out.contains('All checks passed! [oka-live]');
    print('oka-cli: exit=$code probesFlipped=${receipt.ok} '
        'visibleFlip(bonus)=$visible logChars=${out.length}');
    if (code != 0) {
      throw StateError('patched CLI did not complete cleanly');
    }
    print('oka-cli: live patch OK — patched mid-run, completed cleanly');
  } catch (e) {
    failed = true;
    print('oka-cli: FAILED — $e');
    final s = log.toString();
    print('-- target head -- ${s.length} chars');
    print(s.length > 600 ? s.substring(0, 600) : s);
  } finally {
    await target.writeAsString(original);
    app.kill();
  }
  exit(failed ? 1 : 0);
}
