import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _stdinQuitOwner = r'''
#!/bin/sh
set -e
ROOT="$1"
mkdir -p "$ROOT/.flutter_mcp"
cat > "$ROOT/.flutter_mcp/runner-session.json" <<'JSON'
{"schema":1,"runner":"fake","vm_service_uri":"http://127.0.0.1:1/x","control_port":0,"device_id":"emu","pid":1,"started_at":"2026-01-01T00:00:00.000Z"}
JSON
while read -r line; do
  case "$line" in quit|exit)
    rm -f "$ROOT/.flutter_mcp/runner-session.json"
    exit 0
    ;;
  esac
done
''';

Future<Process> _startDartOwner({
  required Directory root,
  required int controlPort,
}) {
  final script = p.join('test', 'cooperative_stop_owner.dart');
  return Process.start('dart', ['run', script, root.path, '$controlPort']);
}

Future<void> _waitForDiscoveryFile(Directory root) async {
  for (var i = 0; i < 40; i++) {
    if (readRunnerSessionFile(root.path) != null) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('runner-session.json never appeared under ${root.path}');
}

Future<void> _alignDiscoveryPid(
  Directory root,
  Process child, {
  required int controlPort,
}) async {
  final live = readRunnerSessionFile(root.path);
  if (live == null) return;
  await writeRunnerSessionFile(
    root.path,
    vmServiceUri: live.vmServiceUri,
    controlPort: controlPort,
    deviceId: live.deviceId,
    processPid: child.pid,
  );
}

/// Forces [RunnerSessionSpawnBinding.unknown] for fail-closed stop tests.
final class _UnavailableProcessTreeProbe implements ProcessTreeProbe {
  const _UnavailableProcessTreeProbe();

  @override
  Future<ProcessTree?> enumerate(int rootPid) async => null;
}

Future<Process> _startOwnerShell({
  required Directory root,
  required String scriptBody,
}) async {
  final script = File(p.join(root.path, 'owner.sh'))..writeAsStringSync(scriptBody);
  await Process.run('chmod', ['+x', script.path]);
  return Process.start(script.path, [root.path]);
}

void main() {
  test('stopOkaDevAndroidSession splits stdin written vs TCP ack', () async {
    final root = await Directory.systemTemp.createTemp('oka_stop_');
    addTearDown(() => root.delete(recursive: true));
    final process = await _startOwnerShell(
      root: root,
      scriptBody: _stdinQuitOwner,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final report = await stopOkaDevAndroidSession(
      owningProcess: process,
      projectPath: root.path,
      controlPort: 0,
      quitTimeout: const Duration(seconds: 10),
    );
    expect(report.stdinQuitWritten, isTrue);
    expect(report.controlQuitAcknowledged, isFalse);
    expect(report.controlQuitSent, isFalse);
    expect(report.controlQuitConnectFailed, isFalse);
    expect(report.runnerSessionCleared, isTrue);
    expect(report.processExitCode, 0);
    expect(report.disposition, DevSessionStopDisposition.cooperative);
    expect(report.ok, isTrue);
  });

  test(
    'TCP quit ack clears discovery and exits cooperative',
    () async {
      final root = await Directory.systemTemp.createTemp('oka_stop_tcp');
      addTearDown(() => root.delete(recursive: true));
      late Process child;
      final server = await DevControlServer.start(
        info: const DevControlSessionInfo(
          deviceId: 'emu',
          target: 'lib/main.dart',
          mode: 'debug',
        ),
        onCommand: (cmd) {
          if (cmd == DevControlCommand.quit) {
            unawaited(clearRunnerSessionFile(root.path));
            child.stdin.writeln('stop');
          }
        },
      );
      addTearDown(server.close);
      child = await _startDartOwner(root: root, controlPort: server.port);
      await _waitForDiscoveryFile(root);
      await _alignDiscoveryPid(root, child, controlPort: server.port);
      final report = await stopOkaDevAndroidSession(
        owningProcess: child,
        projectPath: root.path,
        controlPort: server.port,
        stdinJsonQuitEnabled: false,
        quitTimeout: const Duration(seconds: 15),
      );
      expect(report.controlQuitSent, isTrue);
      expect(report.controlQuitAcknowledged, isTrue);
      expect(report.controlReplyLost, isFalse);
      expect(report.controlQuitConnectFailed, isFalse);
      expect(report.stdinQuitWritten, isFalse);
      expect(report.runnerSessionCleared, isTrue);
      expect(report.processExitCode, 0);
      expect(report.disposition, DevSessionStopDisposition.cooperative);
      expect(report.ok, isTrue);
    },
  );

  test(
    'TCP quit flushed but EOF before reply still cooperative when session ends',
    () async {
      final root = await Directory.systemTemp.createTemp('oka_stop_eof');
      addTearDown(() => root.delete(recursive: true));
      late Process child;
      final server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(server.close);
      server.listen((socket) {
        socket
            .map(utf8.decode)
            .transform(const LineSplitter())
            .listen((line) {
              final decoded = jsonDecode(line) as Map<String, Object?>;
              if (decoded['method'] == 'quit') {
                unawaited(clearRunnerSessionFile(root.path));
                child.stdin.writeln('stop');
                socket.destroy();
              }
            });
      });
      child = await _startDartOwner(root: root, controlPort: server.port);
      await _waitForDiscoveryFile(root);
      await _alignDiscoveryPid(root, child, controlPort: server.port);
      final report = await stopOkaDevAndroidSession(
        owningProcess: child,
        projectPath: root.path,
        controlPort: server.port,
        stdinJsonQuitEnabled: false,
        quitTimeout: const Duration(seconds: 15),
      );
      expect(report.controlQuitSent, isTrue);
      expect(report.controlQuitAcknowledged, isFalse);
      expect(report.controlReplyLost, isTrue);
      expect(report.controlQuitConnectFailed, isFalse);
      expect(report.runnerSessionCleared, isTrue);
      expect(report.processExitCode, 0);
      expect(report.disposition, DevSessionStopDisposition.cooperative);
      expect(report.ok, isTrue);
    },
  );

  test(
    'unknown spawn binding skips TCP and falls back to stdin quit',
    () async {
      final root = await Directory.systemTemp.createTemp('oka_stop_unknown');
      addTearDown(() => root.delete(recursive: true));
      var tcpSeen = false;
      final server = await DevControlServer.start(
        info: const DevControlSessionInfo(
          deviceId: 'emu',
          target: 'lib/main.dart',
          mode: 'debug',
        ),
        onCommand: (_) {
          tcpSeen = true;
        },
      );
      addTearDown(server.close);
      final process = await _startOwnerShell(
        root: root,
        scriptBody: _stdinQuitOwner,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await writeRunnerSessionFile(
        root.path,
        vmServiceUri: 'http://127.0.0.1:1/x',
        controlPort: server.port,
        deviceId: 'emu',
        processPid: 9_999_999,
      );
      final report = await stopOkaDevAndroidSession(
        owningProcess: process,
        projectPath: root.path,
        controlPort: server.port,
        spawnBindingProbe: const _UnavailableProcessTreeProbe(),
        quitTimeout: const Duration(seconds: 10),
      );
      expect(tcpSeen, isFalse);
      expect(report.controlQuitSent, isFalse);
      expect(report.controlQuitAcknowledged, isFalse);
      expect(report.controlQuitConnectFailed, isFalse);
      expect(report.controlReplyLost, isFalse);
      expect(report.stdinQuitWritten, isTrue);
      expect(report.controlResponse?['error'], contains('skipping control quit'));
      expect(report.runnerSessionCleared, isTrue);
      expect(report.disposition, DevSessionStopDisposition.cooperative);
    },
  );

  test('skips TCP when runner-session file is already absent', () async {
    final root = await Directory.systemTemp.createTemp('oka_stop_nofile');
    addTearDown(() => root.delete(recursive: true));
    final process = await _startOwnerShell(
      root: root,
      scriptBody: _stdinQuitOwner,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await clearRunnerSessionFile(root.path);
    final report = await stopOkaDevAndroidSession(
      owningProcess: process,
      projectPath: root.path,
      controlPort: 31999,
      quitTimeout: const Duration(seconds: 10),
    );
    expect(report.controlQuitSent, isFalse);
    expect(report.controlQuitConnectFailed, isFalse);
    expect(report.controlReplyLost, isFalse);
    expect(report.stdinQuitWritten, isTrue);
    expect(report.runnerSessionCleared, isTrue);
    expect(report.disposition, DevSessionStopDisposition.cooperative);
  });

  test('connection refused does not count as control quit sent', () async {
    final root = await Directory.systemTemp.createTemp('oka_stop_refused');
    addTearDown(() => root.delete(recursive: true));
    const deadPort = 31999;
    final process = await _startDartOwner(root: root, controlPort: deadPort);
    await _waitForDiscoveryFile(root);
    // Fail-closed gate requires plausible ownership before any TCP dial.
    await _alignDiscoveryPid(root, process, controlPort: deadPort);
    final session = readRunnerSessionFile(root.path)!;
    final binding = await verifyRunnerSessionSpawnBindingPids(
      discoveryPid: session.pid,
      spawnPid: process.pid,
    );
    expect(
      binding.isPlausibleOwnership,
      isTrue,
      reason: 'fixture must pass ownership before refused-connect',
    );
    final report = await stopOkaDevAndroidSession(
      owningProcess: process,
      projectPath: root.path,
      controlPort: deadPort,
      stdinJsonQuitEnabled: false,
      quitTimeout: const Duration(seconds: 10),
    );
    addTearDown(() => process.kill(ProcessSignal.sigkill));
    expect(report.controlQuitConnectFailed, isTrue);
    expect(report.controlQuitSent, isFalse);
    expect(report.controlReplyLost, isFalse);
    expect(report.stdinQuitWritten, isFalse);
    expect(report.disposition, isNot(DevSessionStopDisposition.cooperative));
  });
}
