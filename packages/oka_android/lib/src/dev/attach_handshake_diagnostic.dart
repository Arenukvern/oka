import 'dart:convert';
import 'dart:io';

import 'daemon_adapter.dart';

const attachHandshakeDiagnosticFileName = 'attach-handshake-failure.json';

/// Persisted when attach never reaches `app.started` (bounded, failure-only).
Future<void> writeAttachHandshakeDiagnostic({
  required String projectPath,
  required List<String> flutterAttachArgv,
  required FlutterDaemonAdapter adapter,
  String? deviceDebugUrl,
  int? deviceVmServicePort,
  int? hostVmServicePort,
  String? primaryError,
}) async {
  final dir = Directory('$projectPath/.flutter_mcp');
  await dir.create(recursive: true);
  final payload = <String, Object?>{
    'schema': 1,
    'primaryError': primaryError,
    'flutterAttachArgv': flutterAttachArgv,
    'vmService': Map<String, Object?>.fromEntries([
      if (deviceDebugUrl != null)
        MapEntry('logcatDeviceDebugUrl', deviceDebugUrl),
      if (deviceVmServicePort != null)
        MapEntry('devicePort', deviceVmServicePort),
      if (hostVmServicePort != null)
        MapEntry('hostForwardPort', hostVmServicePort),
    ]),
    'machineEvents': adapter.snapshotMachineEvents(),
    'stderrTail': adapter.stderrTail,
    'attachExited': adapter.exited,
    'appStartReceived': adapter.appStartReceived,
  };
  await File('${dir.path}/$attachHandshakeDiagnosticFileName').writeAsString(
    '${jsonEncode(payload)}\n',
  );
}

Future<void> clearAttachHandshakeDiagnostic(String projectPath) async {
  final file = File(
    '$projectPath/.flutter_mcp/$attachHandshakeDiagnosticFileName',
  );
  if (file.existsSync()) {
    await file.delete();
  }
}
