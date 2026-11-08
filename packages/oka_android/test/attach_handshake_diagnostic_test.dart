import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:oka_android/src/dev/attach_handshake_diagnostic.dart';
import 'package:test/test.dart';

import '../../../test/adr0011_daemon_adapter_test.dart' show FakeDaemonTransport;

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
        sidecarWriteForTest: (_, _) async {
          throw const FileSystemException('disk full');
        },
      );
      expect(ok, isFalse);
      adapter.dispose();
    });

    test('sessionIdentity null when runner-session absent', () async {
      final t = FakeDaemonTransport();
      final adapter = FlutterDaemonAdapter(transport: t);
      final payload = buildAttachHandshakeDiagnosticPayload(
        flutterAttachArgv: const ['attach', '--machine'],
        adapter: adapter,
        primaryError: 'timed out waiting for app.start',
        sessionIdentity: null,
      );
      expect(payload['sessionIdentity'], isNull);
      adapter.dispose();
    });
  });
}
