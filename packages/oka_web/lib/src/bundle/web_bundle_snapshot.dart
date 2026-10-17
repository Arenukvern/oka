import 'dart:io';
import 'dart:typed_data';

import 'web_bundle_manifest.dart';

/// Verified immutable output bytes, independent of subsequent filesystem edits.
/// Memory is bounded by the caller; this is not a compiler input cache.
class WebBundleSnapshot {
  WebBundleSnapshot._(this.manifest, this._bytes);
  final WebBundleManifest manifest;
  final Map<String, Uint8List> _bytes;
  String get digest => manifest.digest;
  int get byteLength =>
      manifest.files.values.fold(0, (n, file) => n + file.bytes);

  static Future<WebBundleSnapshot> load({
    required Directory directory,
    required WebBundleManifest manifest,
    required int maxBytes,
  }) async {
    if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    final total = manifest.files.values.fold(0, (n, file) => n + file.bytes);
    if (total > maxBytes) {
      throw StateError('Bundle exceeds snapshot byte budget');
    }
    final bytes = <String, Uint8List>{};
    for (final path in manifest.files.keys) {
      bytes[path] = (await manifest.readVerified(
        directory,
        path,
      )).asUnmodifiableView();
    }
    return WebBundleSnapshot._(manifest, Map.unmodifiable(bytes));
  }

  Uint8List read(String path) {
    final bytes = _bytes[path];
    if (bytes == null) throw StateError('File outside bundle snapshot: $path');
    return bytes;
  }

  /// Asset route usable alongside a separately composed entry page.
  /// It preserves asset bytes; it does not rewrite Flutter base/loader URLs.
  Uri assetUri(String path) {
    read(path);
    return Uri(pathSegments: ['', 'bundles', digest, ...path.split('/')]);
  }

  Uint8List readAssetUri(Uri uri) {
    final parts = uri.pathSegments;
    if (uri.hasAuthority ||
        uri.hasScheme ||
        uri.hasQuery ||
        uri.hasFragment ||
        parts.length < 3 ||
        parts[0] != 'bundles' ||
        parts[1] != digest) {
      throw StateError('URI outside bundle identity: $uri');
    }
    return read(parts.skip(2).join('/'));
  }
}
