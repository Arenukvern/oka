/// Product-families leg 3 (ADR-0035 §2e): live-patch a Flutter desktop app
/// mid-boot — vosges (`apps/desktop` on macOS).
///
/// Bring-up is the harness's job (ADR-0036 Tier 1):
/// `FlutterRunTarget.launch()` owns the `flutter run` session and returns
/// `LaunchedApp` with a `LogTap` (assert with `waitFor`, never
/// sleep-and-grep) and the VM service `vmUri`. The delta is compiled with
/// **the app's own frontend** (`frontend_server_aot.dart.snapshot` from
/// the flutter cache, against the flutter patched SDK) — a delta from a
/// foreign frontend fails to parse in the app's VM and falls into the
/// kernel-isolate lane, which desktop engines don't start. Apply = DevFS
/// push + `reloadSources {pause: false, rootLibUri}` (flutter's shape).
///
/// Env: VOSGES_APP_ROOT, FLUTTER_BIN.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_mcp_harness/flutter_mcp_harness.dart';

import 'flutter_delta.dart';
import 'package:oka_update/oka_update.dart';

// ignore_for_file: avoid_print, cancel_subscriptions, unused_local_variable, unintended_html_in_doc_comment, prefer_expression_function_bodies, avoid_redundant_argument_values

final home = Platform.environment['HOME']!;
final appRoot = Platform.environment['VOSGES_APP_ROOT'] ??
    '$home/xs/storage_problem/vosges/apps/desktop';
final wsRoot = Platform.environment['VOSGES_WS_ROOT'] ??
    '$home/xs/storage_problem/vosges';
final flutterBin =
    Platform.environment['FLUTTER_BIN'] ?? '$home/fvm/default/bin/flutter';

const unitFile = 'packages/vosges_core/lib/src/hand_identity.dart';

Future<void> main() async {
  final (dartSdk, frontend, patchedSdk) = flutterToolchainPaths(flutterBin);
  final compile = flutterFrontendDeltaCompiler(
      frontend, dartSdk, patchedSdk, '$wsRoot/.dart_tool/package_config.json');

  final target = File('$wsRoot/$unitFile');
  final original = await target.readAsString();
  final log = <String>[];
  final app = await FlutterRunTarget(
    projectDir: appRoot,
    device: 'macos',
    flutterBin: flutterBin,
    name: 'vosges-app',
    onLine: log.add,
  ).launch();
  var failed = false;
  try {
    // The harness scrapes the service's http URI (`…/TOKEN=`); DevFS
    // needs it with the trailing slash, the wire needs the ws form.
    final httpBase = app.vmUri.toString();
    final wsUri = '${httpBase.replaceFirst('http', 'ws')}/ws';
    print('vosges-app: VM service at $wsUri — patching mid-boot');

    final receipt = await runLivePatch(
      LivePatchSpec(
        revision: 'vosges-live-1',
        unit: 'vosges_hand_identity',
        patches: const [
          PatchEdit(
            file: unitFile,
            find: '  if (landmarks.length < 21) return 0;',
            replace: '''
  if (landmarks.length < 21) {
    if (landmarks.isEmpty) return 3;
    return 0;
  }''',
          ),
        ],
        targets: [
          TargetSpec(
            kind: 'vm',
            id: 'vosges-app',
            ws: wsUri,
            http: httpBase,
            devfs: 'oka_vosges_live',
            // Desktop embedders don't start the kernel isolate, and a
            // failed _reloadKernel kills the app: go straight to the
            // reloadSources(rootLibUri) shape flutter's own hot reload
            // uses, with the delta from the app's own frontend.
            applyVia: 'reloadSources',
          ),
        ],
        probes: const [
          ProbeSpec(
            library: 'hand_identity.dart',
            expression: 'palmPlaneSign(const [])',
            expect: '3',
          ),
          ProbeSpec(
            library: 'hand_identity.dart',
            expression: 'handScaleOf(const [])',
            hold: true,
          ),
        ],
      ),
      compile: compile,
      root: wsRoot,
      onEvent: (e) => print('live: ${e.why}'),
    );
    print(receipt.describe());
    if (!receipt.ok) throw StateError('live patch refused');
    final mode = receipt.targets.first.mode;
    print('vosges-app: live patch OK (mode=$mode, app still booting)');
  } catch (e) {
    failed = true;
    print('vosges-app: FAILED — $e');
    final s = log.join('\n');
    print(s.length > 2500 ? s.substring(s.length - 2500) : s);
  } finally {
    await target.writeAsString(original);
    // `q` = flutter run's graceful quit (terminates the app); the
    // harness's stop() is the escalation path.
    app.process.stdin.writeln('q');
    await app.process.stdin.flush();
    final code = await app.process.exitCode
        .timeout(const Duration(seconds: 40), onTimeout: app.stop);
    print('vosges-app: flutter run exit=$code');
  }
  exit(failed ? 1 : 0);
}
