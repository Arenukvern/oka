import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('readSessionTeardownForOwningStop', () {
    late Directory root;
    const started = '2026-11-08T14:00:00.000Z';
    const expectedDiscovery = SessionTeardownStopExpectation(
      runnerPid: 4371,
      controlPort: 18442,
      sessionStartedAtUtc: started,
    );

    setUp(() async {
      root = await Directory.systemTemp.createTemp('oka-stop-sidecar-');
    });

    tearDown(() async {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    test('all three identity fields must match discovery snapshot', () async {
      await writeSessionTeardownFile(
        root.path,
        const DevSessionTeardownReport(
          forward: ForwardReleaseAction(attempted: true, removed: true),
        ),
        identity: const SessionTeardownIdentity(
          runnerPid: 4371,
          controlPort: 18442,
          sessionStartedAtUtc: started,
        ),
      );
      expect(
        readSessionTeardownForOwningStop(
          projectPath: root.path,
          expectedDiscovery: expectedDiscovery,
        ),
        isNotNull,
      );
    });

    test('spawn pid differs from discovery owner — match on owner not spawn',
        () async {
      await writeSessionTeardownFile(
        root.path,
        const DevSessionTeardownReport(
          forward: ForwardReleaseAction(attempted: true, removed: true),
        ),
        identity: const SessionTeardownIdentity(
          runnerPid: 4371,
          controlPort: 18442,
          sessionStartedAtUtc: started,
        ),
      );
      const spawnPid = 4353;
      final wrongSpawn = SessionTeardownStopExpectation(
        runnerPid: spawnPid,
        controlPort: expectedDiscovery.controlPort,
        sessionStartedAtUtc: expectedDiscovery.sessionStartedAtUtc,
      );
      expect(
        readSessionTeardownForOwningStop(
          projectPath: root.path,
          expectedDiscovery: wrongSpawn,
        ),
        isNull,
      );
      expect(
        readSessionTeardownForOwningStop(
          projectPath: root.path,
          expectedDiscovery: expectedDiscovery,
        ),
        isNotNull,
      );
    });

    test('rejects missing identity', () async {
      await writeSessionTeardownFile(
        root.path,
        const DevSessionTeardownReport(),
      );
      expect(
        readSessionTeardownForOwningStop(
          projectPath: root.path,
          expectedDiscovery: expectedDiscovery,
        ),
        isNull,
      );
    });

    test('rejects stale controlPort', () async {
      await writeSessionTeardownFile(
        root.path,
        const DevSessionTeardownReport(),
        identity: SessionTeardownIdentity(
          runnerPid: expectedDiscovery.runnerPid,
          controlPort: 99999,
          sessionStartedAtUtc: expectedDiscovery.sessionStartedAtUtc,
        ),
      );
      expect(
        readSessionTeardownForOwningStop(
          projectPath: root.path,
          expectedDiscovery: expectedDiscovery,
        ),
        isNull,
      );
    });

    test('rejects mismatched startedAt', () async {
      await writeSessionTeardownFile(
        root.path,
        const DevSessionTeardownReport(),
        identity: const SessionTeardownIdentity(
          runnerPid: 4371,
          controlPort: 18442,
          sessionStartedAtUtc: '2026-01-01T00:00:00.000Z',
        ),
      );
      expect(
        readSessionTeardownForOwningStop(
          projectPath: root.path,
          expectedDiscovery: expectedDiscovery,
        ),
        isNull,
      );
    });
  });

  group('stopOkaDevAndroidSession reads sidecar', () {
    test('owner identity in sidecar readable when spawn pid differs', () async {
      final root = await Directory.systemTemp.createTemp('oka-stop-int-');
      addTearDown(() => root.delete(recursive: true));
      const ownerPid = 4371;
      const controlPort = 18442;
      const started = '2026-11-08T14:00:00.000Z';

      final script = File(p.join(root.path, 'quit.sh'))
        ..writeAsStringSync(r'''
#!/bin/sh
set -e
ROOT="$1"
while read -r line; do
  case "$line" in quit|exit)
    rm -f "$ROOT/.flutter_mcp/runner-session.json"
    exit 0
    ;;
  esac
done
''');
      await Process.run('chmod', ['+x', script.path]);
      final spawn = await Process.start(script.path, [root.path]);

      await writeRunnerSessionFile(
        root.path,
        vmServiceUri: 'http://127.0.0.1:1/x',
        controlPort: controlPort,
        deviceId: 'emu',
        processPid: ownerPid,
        startedAt: DateTime.parse(started),
      );

      await writeSessionTeardownFile(
        root.path,
        const DevSessionTeardownReport(
          attachDaemon: DaemonDisposeReport(
            shutdownAttempted: true,
            shutdownAcknowledged: true,
            processExited: true,
            killedAsBackstop: false,
          ),
        ),
        identity: const SessionTeardownIdentity(
          runnerPid: ownerPid,
          controlPort: controlPort,
          sessionStartedAtUtc: started,
        ),
      );

      expect(spawn.pid, isNot(ownerPid));

      final report = await stopOkaDevAndroidSession(
        owningProcess: spawn,
        projectPath: root.path,
        controlPort: 0,
        quitTimeout: const Duration(seconds: 8),
      );

      expect(report.sessionCleanup, isNotNull);
      expect(report.sessionCleanupActionsSucceeded, isTrue);
      expect(report.sessionCleanup!['identity'], isA<Map<String, Object?>>());
      final id = report.sessionCleanup!['identity']! as Map<String, Object?>;
      expect(id['runnerPid'], ownerPid);
    });
  });
}
