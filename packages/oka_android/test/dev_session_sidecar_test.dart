import 'dart:convert';
import 'dart:io';

import 'package:oka_android/src/dev/dev_session_teardown.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  const started = '2026-11-08T12:00:00.000Z';
  const expectedDiscovery = SessionTeardownStopExpectation(
    runnerPid: 4242,
    controlPort: 5555,
    sessionStartedAtUtc: started,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('oka-sidecar-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('teardown sidecar requires matching discovery triple', () async {
    await writeSessionTeardownFile(
      root.path,
      const DevSessionTeardownReport(
        forward: ForwardReleaseAction(attempted: true, removed: true),
      ),
      identity: const SessionTeardownIdentity(
        runnerPid: 4242,
        controlPort: 5555,
        sessionStartedAtUtc: started,
      ),
    );
    final matched = readSessionTeardownForOwningStop(
      projectPath: root.path,
      expectedDiscovery: expectedDiscovery,
    );
    expect(matched, isNotNull);
    expect(matched!['actionsSucceeded'], isTrue);
    expect(matched['identity'], isA<Map<String, Object?>>());
  });

  test('clear on next prepare overwrites path', () async {
    await writeSessionTeardownFile(
      root.path,
      const DevSessionTeardownReport(),
    );
    await clearSessionTeardownFile(root.path);
    expect(readSessionTeardownFile(root.path), isNull);
  });

  test('round-trip json schema', () async {
    await writeSessionTeardownFile(
      root.path,
      const DevSessionTeardownReport(),
      identity: const SessionTeardownIdentity(
        runnerPid: 1,
        controlPort: 9,
        sessionStartedAtUtc: 't',
      ),
    );
    final text = await File(
      '${root.path}/.flutter_mcp/$sessionTeardownFileName',
    ).readAsString();
    final map = jsonDecode(text) as Map<String, Object?>;
    expect(map['schema'], 1);
    expect(map['identity'], isNotNull);
  });
}
