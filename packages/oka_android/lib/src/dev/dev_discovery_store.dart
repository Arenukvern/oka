import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

final class DevSessionDiscoveryRecord {
  const DevSessionDiscoveryRecord({
    required this.vmServiceUri,
    required this.controlPort,
    required this.deviceId,
    required this.pid,
    required this.startedAt,
  });

  final String vmServiceUri;
  final int controlPort;
  final String deviceId;
  final int pid;
  final DateTime startedAt;
}

abstract interface class DevDiscoveryStore {
  String vmUriPath(String projectPath);
  String runnerSessionPath(String projectPath);
  Future<void> writeVmUri(String projectPath, String uri);
  Future<void> clearVmUri(String projectPath);
  Future<void> writeRunnerSession(
    String projectPath, {
    required String vmServiceUri,
    required int controlPort,
    required String deviceId,
    int? processPid,
    DateTime? startedAt,
  });
  Future<void> clearRunnerSession(String projectPath);
  DevSessionDiscoveryRecord? readRunnerSession(String projectPath);
}

final class FileDevDiscoveryStore implements DevDiscoveryStore {
  const FileDevDiscoveryStore();

  @override
  String vmUriPath(String projectPath) =>
      p.join(projectPath, '.oka_cache', 'dev', 'vm.uri');

  @override
  String runnerSessionPath(String projectPath) =>
      p.join(projectPath, '.flutter_mcp', 'runner-session.json');

  @override
  Future<void> writeVmUri(String projectPath, String uri) async {
    try {
      final file = File(vmUriPath(projectPath));
      await file.parent.create(recursive: true);
      await file.writeAsString('$uri\n', flush: true);
    } on FileSystemException {
      // Discovery is advisory.
    }
  }

  @override
  Future<void> clearVmUri(String projectPath) => _clear(vmUriPath(projectPath));

  @override
  Future<void> writeRunnerSession(
    String projectPath, {
    required String vmServiceUri,
    required int controlPort,
    required String deviceId,
    int? processPid,
    DateTime? startedAt,
  }) async {
    try {
      final file = File(runnerSessionPath(projectPath));
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert({
          'schema': 1,
          'runner': 'oka-dev',
          'vm_service_uri': vmServiceUri,
          'control_port': controlPort,
          'device_id': deviceId,
          'pid': processPid ?? pid,
          'started_at': (startedAt ?? DateTime.now().toUtc()).toIso8601String(),
        })}\n',
        flush: true,
      );
    } on FileSystemException {
      // Discovery is advisory.
    }
  }

  @override
  Future<void> clearRunnerSession(String projectPath) =>
      _clear(runnerSessionPath(projectPath));

  @override
  DevSessionDiscoveryRecord? readRunnerSession(String projectPath) {
    final path = runnerSessionPath(projectPath);
    final file = File(path);
    if (!file.existsSync()) return null;
    late final Map<String, Object?> json;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) {
        throw const FormatException('runner-session root must be an object');
      }
      json = decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    } on FormatException catch (error) {
      throw FormatException(
        'Unreadable $path: ${error.message}\n'
        '   fix: delete the stale file (or let the owning `oka dev` exit — '
        'it clears it) and re-run.',
      );
    }
    final schema = json['schema'];
    if (schema != 1) {
      throw FormatException(
        'Unsupported runner-session.json schema: $schema (supported: 1).\n'
        '   fix: re-run `oka dev` to rewrite the file with the current '
        'schema, or upgrade the reader.',
      );
    }
    final uri = json['vm_service_uri'];
    final port = json['control_port'];
    final device = json['device_id'];
    final processPid = json['pid'];
    final startedAt = json['started_at'];
    if (uri is! String || port is! int || device is! String ||
        processPid is! int || startedAt is! String) {
      throw FormatException(
        'Incomplete $path — all fields (schema, vm_service_uri, '
        'control_port, device_id, pid, started_at) are required.\n'
        '   fix: re-run `oka dev` to rewrite the file.',
      );
    }
    return DevSessionDiscoveryRecord(
      vmServiceUri: uri,
      controlPort: port,
      deviceId: device,
      pid: processPid,
      startedAt: DateTime.parse(startedAt),
    );
  }

  Future<void> _clear(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already absent.
    }
  }
}
