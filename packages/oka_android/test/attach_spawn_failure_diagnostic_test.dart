import 'dart:convert';
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('oka_spawn_diag_');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('spawn failure diagnostic records forward release attempt and exit code',
      () async {
    await tryWriteAttachSpawnFailureDiagnostic(
      projectPath: root.path,
      primaryError: 'spawn failed',
      flutterAttachArgv: const ['attach', '--machine'],
      forwardRelease: const DevLaunchForwardReleaseResult(
        attempted: true,
        removed: false,
        adbExitCode: 1,
      ),
      hostVmServicePort: 36605,
    );
    final payload = jsonDecode(
      File(
        '${root.path}/.flutter_mcp/$attachHandshakeDiagnosticFileName',
      ).readAsStringSync(),
    ) as Map<String, Object?>;
    expect(payload['forwardReleaseAttempted'], isTrue);
    expect(payload['forwardReleaseRemoved'], isFalse);
    expect(payload['forwardReleaseAdbExitCode'], 1);
    expect(payload['forwardReleased'], isTrue);
    expect(payload['kind'], 'attach_spawn_failure');
  });
}
