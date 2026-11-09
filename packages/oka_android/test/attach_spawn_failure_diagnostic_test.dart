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

  test('spawn failure diagnostic records forwardReleased', () async {
    await tryWriteAttachSpawnFailureDiagnostic(
      projectPath: root.path,
      primaryError: 'spawn failed',
      flutterAttachArgv: const ['attach', '--machine'],
      forwardReleased: true,
      hostVmServicePort: 36605,
    );
    final payload = jsonDecode(
      File(
        '${root.path}/.flutter_mcp/$attachHandshakeDiagnosticFileName',
      ).readAsStringSync(),
    ) as Map<String, Object?>;
    expect(payload['forwardReleased'], isTrue);
    expect(payload['kind'], 'attach_spawn_failure');
  });
}
