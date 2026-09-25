import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';

const _sessionStateProtocolFramePrefix = '\x1eOKA_SESSION_STATE_V1:';

/// Calls the project composition root's session-state protocol.
///
/// Returns null when no pipeline entrypoint is discoverable so commands can
/// retain their first-party fallback behavior.
Future<Map<String, Object?>?> runProjectSessionState({
  required final String projectPath,
  required final Map<String, Object?> request,
}) async {
  final entrypoint = await findPipelineEntrypoint(projectPath);
  if (entrypoint == null) return null;
  final encodedRequest = jsonEncode({...request, 'protocol_version': 1});
  final process = await Process.run('dart', [
    'run',
    entrypoint,
    '--oka-session-state',
    encodedRequest,
  ], workingDirectory: projectPath);
  final stdoutText = process.stdout as String;
  final stderrText = process.stderr as String;
  if (stderrText.isNotEmpty) stderr.write(stderrText);

  final frames = const LineSplitter()
      .convert(stdoutText)
      .where((final line) => line.startsWith(_sessionStateProtocolFramePrefix))
      .toList();
  if (frames.isEmpty) {
    throw const FormatException(
      'Project entrypoint returned no session-state protocol frame.',
    );
  }
  if (frames.length != 1) {
    throw FormatException(
      'Project entrypoint returned ${frames.length} session-state protocol '
      'frames; expected exactly one.',
    );
  }

  Map<String, Object?> response;
  try {
    final decoded = jsonDecode(
      frames.single.substring(_sessionStateProtocolFramePrefix.length),
    );
    if (decoded is! Map) throw const FormatException('not a JSON object');
    response = decoded.cast<String, Object?>();
  } on Object catch (error) {
    throw FormatException(
      'Project entrypoint returned an invalid session-state response: $error',
    );
  }
  if (response['schema_version'] != 'oka.session-state.protocol.v1' ||
      response['protocol_version'] != 1) {
    throw const FormatException(
      'Project entrypoint uses an unsupported session-state protocol version.',
    );
  }
  if (response['status'] != 'ok' || process.exitCode != 0) {
    throw FormatException(
      response['error']?.toString() ??
          'Project entrypoint session-state operation failed '
              '(exit code ${process.exitCode}).',
    );
  }
  final result = response['result'];
  if (result is! Map) {
    throw const FormatException(
      'Project entrypoint returned no session-state result object.',
    );
  }
  return result.cast<String, Object?>();
}
