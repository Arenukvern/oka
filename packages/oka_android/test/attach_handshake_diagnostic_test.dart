import 'dart:convert';
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

import 'support/fake_daemon_transport.dart';

void main() {
  group('tryWriteAttachHandshakeDiagnostic', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('oka_attach_diag_');
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('returns false when sidecar write throws', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      t.emitEvent('daemon.connected', {'version': '0.6.1'});
      final ok = await tryWriteAttachHandshakeDiagnostic(
        projectPath: root.path,
        flutterAttachArgv: const ['attach', '--machine', '-d', 'emu'],
        adapter: adapter,
        primaryError: 'flutter attach exited before app.started',
        sidecarWriteForTest: (_, _) {
          throw const FileSystemException('disk full');
        },
      );
      expect(ok, isFalse);
      adapter.dispose();
    });

    test('payload keeps primaryError', () {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      const primary = 'flutter attach did not reach app.started within 90s';
      final payload = buildAttachHandshakeDiagnosticPayload(
        flutterAttachArgv: const ['attach', '--machine'],
        adapter: adapter,
        primaryError: primary,
      );
      expect(payload['primaryError'], primary);
      adapter.dispose();
    });
  });

  group('tryRunnerSessionIdentityForDiagnostic', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('oka_attach_diag_');
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('returns null when runner-session is absent', () {
      expect(tryRunnerSessionIdentityForDiagnostic(root.path), isNull);
    });

    test('returns null for malformed runner-session', () {
      final dir = Directory('${root.path}/.flutter_mcp')
        ..createSync(recursive: true);
      File('${dir.path}/runner-session.json').writeAsStringSync('not-json');
      expect(tryRunnerSessionIdentityForDiagnostic(root.path), isNull);
    });

    test('returns null for unknown schema without throwing', () {
      final dir = Directory('${root.path}/.flutter_mcp')
        ..createSync(recursive: true);
      File('${dir.path}/runner-session.json').writeAsStringSync(
        '${jsonEncode({'schema': 99, 'vm_service_uri': 'ws://x', 'control_port': 1, 'device_id': 'd', 'pid': 1, 'started_at': '2026-01-01T00:00:00.000Z'})}\n',
      );
      expect(tryRunnerSessionIdentityForDiagnostic(root.path), isNull);
    });

    test('malformed session does not block sidecar write', () async {
      final dir = Directory('${root.path}/.flutter_mcp')
        ..createSync(recursive: true);
      File('${dir.path}/runner-session.json').writeAsStringSync('{');
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      const primary = 'timed out before app.start';
      final ok = await tryWriteAttachHandshakeDiagnostic(
        projectPath: root.path,
        flutterAttachArgv: const ['attach', '--machine', '-d', 'emu'],
        adapter: adapter,
        primaryError: primary,
        sessionIdentity: tryRunnerSessionIdentityForDiagnostic(root.path),
      );
      expect(ok, isTrue);
      final written = jsonDecode(
        File(
          '${root.path}/.flutter_mcp/$attachHandshakeDiagnosticFileName',
        ).readAsStringSync(),
      ) as Map<String, Object?>;
      expect(written['primaryError'], primary);
      expect(written['sessionIdentity'], isNull);
      adapter.dispose();
    });
  });
}
