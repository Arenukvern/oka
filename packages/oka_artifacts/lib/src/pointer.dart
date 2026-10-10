/// The git-side manifest (ADR-0043 decision 1): ~200 bytes naming the
/// bytes elsewhere. The content hash *is* the integrity check — a
/// fetched artifact whose digest differs is simply not this artifact.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// Provenance-bound pointer to one stored artifact.
final class ArtifactPointer {
  const ArtifactPointer({
    required this.name,
    required this.sha256,
    required this.backend,
    required this.sdkVersion,
    required this.inputsHash,
    this.entrypoint,
    this.createdAt,
  });

  factory ArtifactPointer.fromJson(final Map<String, Object?> json) =>
      ArtifactPointer(
        name: json['name']! as String,
        sha256: json['sha256']! as String,
        backend: json['backend']! as String,
        sdkVersion: json['sdkVersion']! as String,
        inputsHash: json['inputsHash']! as String,
        entrypoint: json['entrypoint'] as String?,
        createdAt: json['createdAt'] == null
            ? null
            : DateTime.parse(json['createdAt']! as String),
      );

  factory ArtifactPointer.fromJsonString(final String contents) =>
      ArtifactPointer.fromJson(jsonDecode(contents) as Map<String, Object?>);

  /// Logical artifact name (must match the chain name in the store).
  final String name;

  /// sha256 of the full artifact bytes; identity and integrity in one.
  final String sha256;

  /// Where `blobs/<sha256>` resolves: e.g. `local`, `https://…/artifacts`.
  final String backend;

  /// Dart VM version the artifact was built with — dills are
  /// SDK-sensitive; a pointer without provenance is a lie.
  final String sdkVersion;

  /// Hash of the input set (source tree, flags) that produced it.
  final String inputsHash;

  final String? entrypoint;

  final DateTime? createdAt;

  Map<String, Object?> toJson() => {
    'name': name,
    'sha256': sha256,
    'backend': backend,
    'sdkVersion': sdkVersion,
    'inputsHash': inputsHash,
    if (entrypoint != null) 'entrypoint': entrypoint,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
  };

  String encode() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  /// Atomic pointer write (temp + rename): a half-written pointer must
  /// never look like a valid one.
  void writeTo(final File target) {
    target.parent.createSync(recursive: true);
    File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp')
      ..writeAsStringSync(encode())
      ..renameSync(target.path);
  }

  static String hashBytes(final List<int> bytes) =>
      crypto.sha256.convert(bytes).toString();

  static bool verify(final List<int> bytes, final String sha256) =>
      hashBytes(bytes) == sha256;
}
