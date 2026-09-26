import 'dart:async';
import 'dart:io';

import 'package:oka_harness/oka_harness.dart';
import 'package:test/test.dart';

/// A fake `oka` CLI: publishes a valid runner-session file (mcp_flutter
/// ADR-0014 spec v2 shape), prints its args, and stays alive like the real
/// owning session.
const String _fakeOkaScript = r'''
#!/bin/sh
echo "fake-oka args: $*"
mkdir -p .flutter_mcp
cat > .flutter_mcp/runner-session.json <<'JSON'
{
  "schema": 1,
  "runner": "fake-oka-dev",
  "vm_service_uri": "http://127.0.0.1:45671/abc123=/",
  "control_port": 45672,
  "device_id": "emulator-5554",
  "pid": 42424,
  "started_at": "2026-09-27T00:00:00.000Z"
}
JSON
echo "fake session published"
sleep 300
''';

/// A fake `oka` that never publishes a session (for the timeout path).
const String _stallingOkaScript = '''
#!/bin/sh
echo "fake-oka stalling"
sleep 300
''';

Future<Directory> _withFakeOka(final String script) async {
  final dir = await Directory.systemTemp.createTemp('oka_harness_test');
  final scriptFile = File('${dir.path}/fake_oka')..writeAsStringSync(script);
  await Process.run('chmod', ['+x', scriptFile.path]);
  return dir;
}

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await _withFakeOka(_fakeOkaScript);
  });

  tearDown(() async {
    await workspace.delete(recursive: true);
  });

  test('launch reads the runner-session contract and returns the VM URI',
      () async {
    final target = AndroidAppTarget(
      projectDir: workspace.path,
      okaBin: '${workspace.path}/fake_oka',
      deviceId: 'emulator-9999',
      logcat: false,
    );
    final app = await target.launch();

    addTearDown(app.stop);
    expect(app.vmUri.host, '127.0.0.1');
    expect(app.vmUri.port, 45671);
    // Args threaded to the owning session.
    expect(
      app.stdout.firstMatch('--device emulator-9999'),
      isNotNull,
    );
    expect(app.stdout.firstMatch('fake session published'), isNotNull);
  });

  test('stop terminates the owning session', () async {
    final target = AndroidAppTarget(
      projectDir: workspace.path,
      okaBin: '${workspace.path}/fake_oka',
      logcat: false,
    );
    final app = await target.launch();
    final code = await app.stop();
    expect(code, isNonZero, reason: 'SIGTERM should end the fake session');
  });

  test('launch(build: false) refuses to double-own the session', () async {
    final target = AndroidAppTarget(
      projectDir: workspace.path,
      okaBin: '${workspace.path}/fake_oka',
    );
    await expectLater(
      target.launch(build: false),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('a session that never publishes times out and is torn down',
      () async {
    final stalling = await _withFakeOka(_stallingOkaScript);
    addTearDown(() => stalling.delete(recursive: true));
    final target = AndroidAppTarget(
      projectDir: stalling.path,
      okaBin: '${stalling.path}/fake_oka',
      logcat: false,
      sessionTimeout: const Duration(seconds: 2),
    );
    await expectLater(target.launch(), throwsA(isA<TimeoutException>()));
    // The failed bring-up must not leave an `oka` process behind.
    final leftover = await Process.run('pgrep', ['-f', 'fake_oka']);
    expect(
      leftover.stdout.toString().trim(),
      isEmpty,
      reason: 'no fake oka process should survive a failed launch',
    );
  });
}
