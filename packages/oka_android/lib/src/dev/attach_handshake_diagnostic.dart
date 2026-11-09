import 'dart:convert';
import 'dart:io';

import 'daemon_adapter.dart';
import 'dev_session_teardown.dart';
import 'vm_service_redaction.dart';

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
  int? attachDdsPort,
  String? primaryError,
  SessionTeardownIdentity? sessionIdentity,
  bool? forwardReleased,
}) {
  final raw = <String, Object?>{
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
      if (attachDdsPort != null) MapEntry('ddsPort', attachDdsPort),
    ]),
    if (sessionIdentity != null) 'sessionIdentity': sessionIdentity.toJson(),
    'machineEventRing': adapter.snapshotMachineEventRing(),
    'stderrTail': adapter.stderrTail,
    'attachExited': adapter.exited,
    'appStartReceived': adapter.appStartReceived,
  };
  if (forwardReleased != null) {
    raw['forwardReleased'] = forwardReleased;
  }
  final redacted = redactVmServiceAuthDeep(raw)! as Map<Object?, Object?>;
  return Map<String, Object?>.from(redacted);
}

/// Persisted when attach never reaches `app.started` (bounded, failure-only).
/// Returns false when the sidecar cannot be written (caller keeps primary error).
Future<bool> tryWriteAttachHandshakeDiagnostic({
  required String projectPath,
  required List<String> flutterAttachArgv,
  required FlutterDaemonAdapter adapter,
  String? deviceDebugUrl,
  int? deviceVmServicePort,
  int? hostVmServicePort,
  int? attachDdsPort,
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
      attachDdsPort: attachDdsPort,
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

Map<String, Object?> buildAttachSpawnFailureDiagnosticPayload({
  required String primaryError,
  required List<String> flutterAttachArgv,
  required bool forwardReleased,
  int? hostVmServicePort,
  int? deviceVmServicePort,
  int? attachDdsPort,
}) {
  final raw = <String, Object?>{
    'schema': 1,
    'kind': 'attach_spawn_failure',
    'primaryError': primaryError,
    'flutterAttachArgv': flutterAttachArgv,
    'forwardReleased': forwardReleased,
    'vmService': Map<String, Object?>.fromEntries([
      if (deviceVmServicePort != null)
        MapEntry('devicePort', deviceVmServicePort),
      if (hostVmServicePort != null)
        MapEntry('hostForwardPort', hostVmServicePort),
      if (attachDdsPort != null) MapEntry('ddsPort', attachDdsPort),
    ]),
  };
  final redacted = redactVmServiceAuthDeep(raw)! as Map<Object?, Object?>;
  return Map<String, Object?>.from(redacted);
}

/// Written when [spawnAttachDaemon] fails after a successful [prepareDevLaunch].
Future<bool> tryWriteAttachSpawnFailureDiagnostic({
  required String projectPath,
  required String primaryError,
  required List<String> flutterAttachArgv,
  required bool forwardReleased,
  int? hostVmServicePort,
  int? deviceVmServicePort,
  int? attachDdsPort,
  AttachHandshakeSidecarWrite? sidecarWriteForTest,
}) async {
  try {
    final dir = Directory('$projectPath/.flutter_mcp');
    await dir.create(recursive: true);
    final payload = buildAttachSpawnFailureDiagnosticPayload(
      primaryError: primaryError,
      flutterAttachArgv: flutterAttachArgv,
      forwardReleased: forwardReleased,
      hostVmServicePort: hostVmServicePort,
      deviceVmServicePort: deviceVmServicePort,
      attachDdsPort: attachDdsPort,
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
