import 'dart:io';

import 'package:oka_harness/oka_harness.dart';

/// Drive an Android app end-to-end through `oka dev` + the toolkit
/// extensions (ADR-0026). Run from a device-connected project root:
///
///   dart run example/emulator_smoke.dart /path/to/flutter_app
///
/// The app must embed `mcp_toolkit` (`MCPToolkitBinding` in `main`) so the
/// snapshot/tap extensions are registered.
Future<void> main(final List<String> args) async {
  final projectDir = args.first;
  final app = await AndroidAppTarget(
    projectDir: projectDir,
    // deviceId: 'emulator-5554', // pin on multi-device hosts
    dartDefines: {'MY_APP_FLOW': 'smoke'},
  ).launch();

  var passed = false;
  try {
    final driver = await driverForLiveSession(projectDir);

    final button = await driver.findRef('start');
    if (button == null) {
      stdout.writeln('FAIL: start button not found in semantic snapshot');
      for (final (label, _) in await driver.snapshot()) {
        stdout.writeln('  node: $label');
      }
    } else {
      await driver.tap(button);
      final confirmation = await driver.findValue(
        (final value) => value.startsWith('SMOKE-'),
      );
      passed = confirmation != null;
      stdout.writeln(
        passed
            ? 'PASS: flow confirmed via $confirmation'
            : 'FAIL: no SMOKE-* value in snapshot',
      );
    }
  } finally {
    await app.stop();
  }
  exit(passed ? 0 : 1);
}
