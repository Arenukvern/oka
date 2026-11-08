import 'dart:convert';
import 'dart:io';

import 'daemon_adapter.dart';
import 'dev_session_teardown.dart';

const attachHandshakeDiagnosticFileName = 'attach-handshake-failure.json';

/// Test hook: replace filesystem write (throws to simulate failure).
typedef AttachHandshakeSidecarWrite =
    Future<void> Function(File file, String body);

Map<String, Object?> buildAttachHandshakeDiagnosticPayload({
  required List<String> flutterAttachArgv,
  required FlutterDaemonAdapter adapter,
  String? deviceDebugUrl,
  int? deviceVmServicePort,
  int? hostVmServicePort,
  String? primaryError,
  SessionTeardownIdentity? sessionIdentity,
}) => {
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
    if (sessionIdentity != null) 'sessionIdentity': sessionIdentity.toJson(),
    'machineEventRing': adapter.snapshotMachineEventRing(),
    'stderrTail': adapter.stderrTail,
    'attachExited': adapter.exited,
    'appStartReceived': adapter.appStartReceived,
  };

/// Persisted when attach never reaches `app.started` (bounded, failure-only).
/// Returns false when the sidecar cannot be written (caller keeps primary error).
Future<bool> tryWriteAttachHandshakeDiagnostic({
  required String projectPath,
  required List<String> flutterAttachArgv,
  required FlutterDaemonAdapter adapter,
  String? deviceDebugUrl,
  int? deviceVmServicePort,
  int? hostVmServicePort,
  String? primaryError,
  SessionTeardownIdentity? sessionIdentity,
  AttachHandshakeSidecarWrite? sidecarWriteForTest,
}) async {
  try {
    final dir = Directory('$projectPath/.flutter_mcp');
    await dir.create(recursive: true);
    final payload = buildAttachHandshakeDiagnosticPayload(
      flutterAttachArgv: flutterAttachArgv,
      adapter: adapter,
      deviceDebugUrl: deviceDebugUrl,
      deviceVmServicePort: deviceVmServicePort,
      hostVmServicePort: hostVmServicePort,
      primaryError: primaryError,
      sessionIdentity: sessionIdentity,
    );
    final body = '${jsonEncode(payload)}\n';
    final file = File('${dir.path}/$attachHandshakeDiagnosticFileName');
    if (sidecarWriteForTest != null) {
      await sidecarWriteForTest(file, body);
    } else {
      await file.writeAsString(body);
    }
    return true;
  } on Object {
    return false;
  }
}

Future<void> clearAttachHandshakeDiagnostic(String projectPath) async {
  final file = File(
    '$projectPath/.flutter_mcp/$attachHandshakeDiagnosticFileName',
  );
  if (file.existsSync()) {
    await file.delete();
  }
}
