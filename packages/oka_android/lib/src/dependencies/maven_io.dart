import 'dart:io';

import 'package:http/http.dart' as http;

// Injectable transport boundary intentionally has one operation.
// ignore: one_member_abstracts
abstract interface class MavenTransport {
  Future<List<int>?> get(Uri uri);
}

class HttpMavenTransport implements MavenTransport {
  // Public parameter name remains `client` for call-site clarity.
  // ignore: prefer_initializing_formals
  HttpMavenTransport({http.Client? client}) : _client = client;

  final http.Client? _client;

  @override
  Future<List<int>?> get(Uri uri) async {
    final client = _client ?? http.Client();
    try {
      final response = await client
          .get(
            uri,
            headers: const {
              'Accept-Encoding': 'identity',
              'User-Agent': 'oka build tool',
            },
          )
          .timeout(const Duration(seconds: 60));
      return response.statusCode == 200 && response.bodyBytes.length > 32
          ? response.bodyBytes
          : null;
    } finally {
      if (_client == null) client.close();
    }
  }
}

abstract interface class MavenArtifactRepository {
  Future<bool> exists(String path);
  Future<int> length(String path);
  Future<List<int>> readBytes(String path);
  Future<String> readText(String path);
  Future<void> writeBytes(String path, List<int> bytes, {bool flush = false});
  Future<void> writeText(String path, String text, {bool flush = false});
  Future<void> delete(String path);
}

class FileMavenArtifactRepository implements MavenArtifactRepository {
  const FileMavenArtifactRepository();

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<int> length(String path) => File(path).length();

  @override
  Future<List<int>> readBytes(String path) => File(path).readAsBytes();

  @override
  Future<String> readText(String path) => File(path).readAsString();

  @override
  Future<void> writeBytes(
    String path,
    List<int> bytes, {
    bool flush = false,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: flush);
  }

  @override
  Future<void> writeText(String path, String text, {bool flush = false}) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(text, flush: flush);
  }

  @override
  Future<void> delete(String path) => File(path).delete();
}
