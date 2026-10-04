/// Channel transports (ADR-0037 §2): the channel is a tree — a pointer,
/// per-revision manifests, artifacts — so any dumb host serves it. Git
/// is one materialization of a file tree; HTTP is another. Nothing in
/// the wire format knows which.
library;

import 'dart:convert';
import 'dart:io';

import 'channel_manifest.dart';

/// Reads a channel. Paths inside artifacts/manifests are relative to the
/// channel root the source is bound to.
abstract interface class ChannelSource {
  Future<ChannelPointer> fetchPointer();

  Future<RevisionNode> fetchManifest(String revision);

  Future<List<int>> fetchArtifact(String file);

  /// The channel history head→baseline (index 0 = head), materialized by
  /// walking `parent` links. [limit] bounds the walk.
  Future<List<RevisionNode>> fetchHistory({int limit = 64});
}

Map<String, dynamic> decodeChannelJson(List<int> bytes, String what) {
  try {
    return (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>();
  } on FormatException catch (e) {
    throw ChannelSourceException('channel file unparsable: $what ($e)');
  }
}

/// A channel materialized as a local directory (the `oka ship` output; a
/// git worktree/branch checkout of the same tree is identical).
class FileChannelSource implements ChannelSource {
  FileChannelSource(this.root);

  final String root;

  File _file(String relative) => File('$root/$relative');

  List<int> _read(String relative) {
    final file = _file(relative);
    if (!file.existsSync()) {
      throw ChannelSourceException('channel file missing: $relative');
    }
    return file.readAsBytesSync();
  }

  @override
  Future<ChannelPointer> fetchPointer() async => ChannelPointer.fromJson(
      decodeChannelJson(_read('pointer.json'), 'pointer.json'));

  @override
  Future<RevisionNode> fetchManifest(String revision) async =>
      RevisionNode.fromJson(
          decodeChannelJson(_read('manifests/$revision.json'), revision));

  @override
  Future<List<int>> fetchArtifact(String file) => Future.value(_read(file));

  @override
  Future<List<RevisionNode>> fetchHistory({int limit = 64}) async {
    final nodes = <RevisionNode>[];
    var cursor =
        await fetchPointer().then((pointer) => pointer.revision);
    while (nodes.length < limit) {
      final node = await fetchManifest(cursor);
      nodes.add(node);
      final parent = node.parent;
      if (parent == null) break;
      cursor = parent;
    }
    return nodes;
  }
}

/// A channel served over plain HTTP(S) — any static host. Content
/// addressing (sha256 per artifact) is what makes a dumb host safe.
class HttpChannelSource implements ChannelSource {
  HttpChannelSource({required String baseUrl, HttpClient? client})
      : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _client = client ?? HttpClient();

  /// Base URL without a trailing slash.
  final String baseUrl;
  final HttpClient _client;

  Future<List<int>> _get(String relative) async {
    final request = await _client
        .getUrl(Uri.parse('$baseUrl/$relative'))
        .timeout(const Duration(seconds: 30));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw ChannelSourceException(
          'GET $relative -> HTTP ${response.statusCode}');
    }
    return response.fold<List<int>>(
        <int>[], (bytes, chunk) => bytes..addAll(chunk));
  }

  @override
  Future<ChannelPointer> fetchPointer() async => ChannelPointer.fromJson(
      decodeChannelJson(await _get('pointer.json'), 'pointer.json'));

  @override
  Future<RevisionNode> fetchManifest(String revision) async =>
      RevisionNode.fromJson(decodeChannelJson(
          await _get('manifests/$revision.json'), revision));

  @override
  Future<List<int>> fetchArtifact(String file) => _get(file);

  @override
  Future<List<RevisionNode>> fetchHistory({int limit = 64}) async {
    final nodes = <RevisionNode>[];
    var cursor =
        await fetchPointer().then((pointer) => pointer.revision);
    while (nodes.length < limit) {
      final node = await fetchManifest(cursor);
      nodes.add(node);
      final parent = node.parent;
      if (parent == null) break;
      cursor = parent;
    }
    return nodes;
  }
}

/// Raised when a source cannot serve a well-formed channel.
class ChannelSourceException implements Exception {
  ChannelSourceException(this.message);
  final String message;

  @override
  String toString() => 'ChannelSourceException: $message';
}
