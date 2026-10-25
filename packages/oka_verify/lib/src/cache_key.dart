/// The cache key of a suite kernel (ADR-0048): what makes a cached kernel
/// stale.
///
/// A kernel is valid only while four things are unchanged: the **source
/// closure** it was compiled from, the **SDK** that compiled it, the
/// **package configuration** it resolved against, and the **bootstrap
/// contract** that shaped its entry point. The key is a pure function of
/// those, so it can be tested without a compiler, a cache directory or a
/// running lane.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// The environment facts every suite key carries.
final class CacheKeyContext {
  const CacheKeyContext({
    required this.sdkVersion,
    required this.packageConfigHash,
    required this.contractVersion,
  });

  /// The context of a running SDK, with the package configuration read
  /// from [packageConfigJson].
  CacheKeyContext.current({
    required String packageConfigJson,
    required this.sdkVersion,
    required this.contractVersion,
  }) : packageConfigHash = hashString(packageConfigJson);

  /// The Dart SDK version that produced the kernel.
  final String sdkVersion;

  /// Content hash of the root `package_config.json`.
  final String packageConfigHash;

  /// Version of the bootstrap contract (bump when the generated entry
  /// point changes shape).
  final String contractVersion;

  @override
  String toString() =>
      'CacheKeyContext(sdk: $sdkVersion, config: $packageConfigHash, '
      'contract: $contractVersion)';
}

/// The content key of one suite: the closure's content plus the environment
/// facts above. Any change anywhere in the closure, the package
/// configuration, the SDK or the contract invalidates the kernel.
///
/// [fileHashes] maps every file of [closure] to its content hash; a file
/// that is missing hashes as [missingFileHash] so a deletion invalidates
/// like any other change.
String computeSuiteKey({
  required List<String> closure,
  required Map<String, String> fileHashes,
  required CacheKeyContext context,
}) {
  final files = closure.toList()..sort();
  final digest = sha256.convert(
    utf8.encode(
      [
        'contract=${context.contractVersion}',
        'sdk=${context.sdkVersion}',
        'packageConfig=${context.packageConfigHash}',
        for (final file in files)
          '$file:${fileHashes[file] ?? missingFileHash}',
      ].join('\n'),
    ),
  );
  return digest.toString();
}

/// The hash used for a file that no longer exists.
const String missingFileHash = '<missing>';

/// The sha256 of a string, hex encoded.
String hashString(String value) =>
    sha256.convert(utf8.encode(value)).toString();

/// The sha256 of a file's bytes, hex encoded. A missing file hashes as
/// [missingFileHash] instead of throwing, so a deleted source invalidates
/// its consumers instead of crashing the lane.
String hashFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return missingFileHash;
  return sha256.convert(file.readAsBytesSync()).toString();
}
