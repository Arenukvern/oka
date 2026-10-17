import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Content identity of all regular files in a built web directory.
/// This describes outputs, not compiler inputs or reproducible compilation.
class WebBundleManifest {
  WebBundleManifest._(this.files);

  factory WebBundleManifest.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != 1 || json['files'] is! List) {
      throw const FormatException('Invalid bundle manifest');
    }
    final rows = <String, ({int bytes, String sha256})>{};
    for (final item in json['files'] as List) {
      if (item is! Map) throw const FormatException('Invalid bundle file');
      final name = item['path'];
      final bytes = item['bytes'];
      final hash = item['sha256'];
      if (name is! String ||
          !_validPath(name) ||
          rows.containsKey(name) ||
          bytes is! int ||
          bytes < 0 ||
          hash is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
        throw const FormatException('Invalid bundle file identity');
      }
      rows[name] = (bytes: bytes, sha256: hash);
    }
    if (rows.isEmpty) throw const FormatException('Empty bundle manifest');
    final sorted = rows.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final manifest = WebBundleManifest._(
      Map.unmodifiable({for (final entry in sorted) entry.key: entry.value}),
    );
    if (json['digest'] != manifest.digest) {
      throw const FormatException('Bundle manifest digest mismatch');
    }
    return manifest;
  }

  final Map<String, ({int bytes, String sha256})> files;

  static Future<WebBundleManifest> capture(Directory directory) async {
    final root = directory.resolveSymbolicLinksSync();
    final rows = <String, ({int bytes, String sha256})>{};
    await for (final entry in Directory(
      root,
    ).list(recursive: true, followLinks: false)) {
      if (entry is Link) {
        throw StateError('Web bundle contains a symbolic link');
      }
      if (entry is! File) continue;
      final name = p.posix.joinAll(p.split(p.relative(entry.path, from: root)));
      if (!_validPath(name)) throw StateError('Unsupported bundle path: $name');
      final before = await entry.stat();
      final hash = (await sha256.bind(entry.openRead()).first).toString();
      final after = await entry.stat();
      if (before.size != after.size || before.modified != after.modified) {
        throw StateError('Web bundle changed during capture: $name');
      }
      rows[name] = (bytes: after.size, sha256: hash);
    }
    if (rows.isEmpty) throw StateError('Web bundle is empty');
    final sorted = rows.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return WebBundleManifest._(
      Map.unmodifiable({for (final entry in sorted) entry.key: entry.value}),
    );
  }

  List<Map<String, Object>> get _rows => [
    for (final row in files.entries)
      {'path': row.key, 'bytes': row.value.bytes, 'sha256': row.value.sha256},
  ];
  String get digest =>
      sha256.convert(utf8.encode(jsonEncode(_rows))).toString();
  Map<String, Object> toJson() => {
    'schema': 1,
    'digest': digest,
    'files': _rows,
  };

  /// Verifies the exact bytes returned for serving. No filesystem mutation.
  Future<Uint8List> readVerified(Directory directory, String path) async {
    if (!_validPath(path) || !files.containsKey(path)) {
      throw StateError('File is outside bundle manifest: $path');
    }
    final root = directory.resolveSymbolicLinksSync();
    var current = root;
    for (final part in path.split('/')) {
      current = p.join(current, part);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('Web bundle path became a symbolic link: $path');
      }
    }
    final file = File(current);
    final expected = files[path]!;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (builder.length + chunk.length > expected.bytes) {
        throw StateError('Web bundle content changed: $path');
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.length != expected.bytes ||
        sha256.convert(bytes).toString() != expected.sha256) {
      throw StateError('Web bundle content changed: $path');
    }
    return bytes;
  }

  /// Added, removed, renamed and changed files all invalidate output identity.
  Future<bool> matches(Directory directory) async =>
      (await capture(directory)).digest == digest;
  static bool _validPath(String path) =>
      path.isNotEmpty &&
      !path.contains(r'\') &&
      !path.contains(':') &&
      !p.posix.isAbsolute(path) &&
      path
          .split('/')
          .every((part) => part.isNotEmpty && part != '.' && part != '..');
}
