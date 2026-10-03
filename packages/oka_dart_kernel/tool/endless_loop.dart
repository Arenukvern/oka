/// The endless dev loop on last_answer's real engine (ADR-0035): patch
/// continue, patch RESET, continue — zero restarts, boot state held
/// throughout.
///
/// Env: LIVE_APP_ROOT (last_answer), plus the toolchain conventions from
/// resolvePipelineToolchain. Targets the endless driver on :8244.
///
/// Steps (each is applyChange — the editor-save flow):
///   1. forward: fractional_order b -> c       (patch continue)
///   2. forward: doc_replica_store -> _live    (patch continue)
///   3. reset:   fractional_order c -> b       (patch reset continue)
///   4. reset:   doc_replica_store _live -> _  (patch reset continue)
/// After EVERY step: the boot-state probe must hold (same replica, same
/// op count) — the process was never restarted.
library;

import 'dart:io';

import 'package:oka_dart_kernel/oka_dart_kernel.dart';
import 'package:oka_update/oka_update.dart';

final appRoot =
    Platform.environment['LIVE_APP_ROOT'] ?? Directory.current.path;

const fracFile = 'packages/headless_core/lib/src/fractional_order.dart';
const storeFile = 'packages/headless_core/lib/src/doc_replica_store.dart';

LivePatchSpec step({
  required String revision,
  required String file,
  required String find,
  required String replace,
  required String expect,
}) =>
    LivePatchSpec(
      revision: revision,
      unit: 'endless',
      patches: [
        PatchEdit(
            file: '$appRoot/$file', find: find, replace: replace),
      ],
      targets: [const TargetSpec.vmPort(8244, id: 'endless-vm')],
      probes: [
        // The change under test.
        ProbeSpec(
            expression: 'orderLabel() + storeLabel()',
            library: 'oka_endless_driver.dart',
            expect: expect),
        // Boot state must hold through every step (no restart, no state
        // loss) — the whole point of the endless loop.
        const ProbeSpec(
          expression: 'stateLabel()',
          library: 'oka_endless_driver.dart',
          hold: true,
        ),
      ],
    );

Future<void> main() async {
  final toolchain = await resolvePipelineToolchain(
    checkout: Platform.environment['OKA_SDK_CHECKOUT'],
    // this file lives in <package>/tool/ — the package root is its parent.
    okaDartKernelRoot:
        File.fromUri(Platform.script).parent.parent.path,
    workDir: Directory.systemTemp,
    // The driver is loaded with the app's package config (dart discovers
    // it upward from tool/) — the delta must be compiled under the SAME
    // config or the reload matches nothing (URI coherence).
    appPackagesConfig: '$appRoot/.dart_tool/package_config.json',
  );
  final compile = pipelineDeltaCompiler(toolchain);

  final steps = <String, LivePatchSpec>{
    'patch continue (fractional b->c)': step(
      revision: 'loop-1',
      file: fracFile,
      // Function-body patch: a const FIELD's canonical value survives a
      // kernel reload, so the loop patches code (a fresh local alphabet
      // inside the new body), not data.
      find: """  return String.fromCharCodes([
    for (final digit in mid) _alphabet.codeUnitAt(digit),
  ]);""",
      replace: """  const patchedAlphabet = 'acbdefghijklmnopqrstuvwxyz';
  return String.fromCharCodes([
    for (final digit in mid) patchedAlphabet.codeUnitAt(digit),
  ]);""",
      expect: '"c"',
    ),
    'patch continue (store -> _live)': step(
      revision: 'loop-2',
      file: storeFile,
      find: "this.dir = 'doc_replicas',",
      replace: "this.dir = 'doc_replicas_live',",
      expect: 'doc_replicas_live',
    ),
    'patch RESET (fractional c->b)': step(
      revision: 'loop-3',
      file: fracFile,
      find: """  const patchedAlphabet = 'acbdefghijklmnopqrstuvwxyz';
  return String.fromCharCodes([
    for (final digit in mid) patchedAlphabet.codeUnitAt(digit),
  ]);""",
      replace: """  return String.fromCharCodes([
    for (final digit in mid) _alphabet.codeUnitAt(digit),
  ]);""",
      expect: '"b"',
    ),
    'patch RESET (store _live -> _)': step(
      revision: 'loop-4',
      file: storeFile,
      find: "this.dir = 'doc_replicas_live',",
      replace: "this.dir = 'doc_replicas',",
      expect: 'store: dir="doc_replicas"',
    ),
  };

  var allOk = true;
  for (final entry in steps.entries) {
    // ignore: avoid_print
    print('== ${entry.key}');
    // Scripted steps use the full run (the spec's find/replace IS the
    // edit); the editor-driven loop uses applyChange/LiveWatcher instead.
    final receipt = await runLivePatch(
      entry.value,
      compile: compile,
      root: appRoot,
      onEvent: (e) => print('live: ${e.why}'),
    );
    // ignore: avoid_print
    print(receipt.describe());
    if (!receipt.ok) {
      allOk = false;
      break;
    }
  }
  exit(allOk ? 0 : 1);
}
