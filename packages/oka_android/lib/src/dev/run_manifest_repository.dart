import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Persistence boundary for `run_session.json`.
abstract interface class RunManifestRepository {
  Map<String, dynamic> read(String path);
  Map<String, dynamic>? readForArtifact(String artifactPath, String fileName);
  Future<File> write(String path, Map<String, dynamic> json);
}

final class FileRunManifestRepository implements RunManifestRepository {
  const FileRunManifestRepository();

  @override
  Map<String, dynamic> read(String path) {
    final file = File(path);
    if (!file.existsSync()) throw FileSystemException('missing', path);
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) {
      throw const FormatException('session manifest root must be an object');
    }
    return decoded.map(
      (key, value) => MapEntry(key.toString(), value),
    );
  }

  @override
  Map<String, dynamic>? readForArtifact(String artifactPath, String fileName) {
    final path = p.join(p.dirname(artifactPath), fileName);
    if (!File(path).existsSync()) return null;
    return read(path);
  }

  @override
  Future<File> write(String path, Map<String, dynamic> json) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    return file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(json)}\n',
      flush: true,
    );
  }
}
