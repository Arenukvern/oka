import 'package:meta/meta.dart';

/// A Maven coordinate — the single canonical typed value (ADR-0006/0007).
///
/// Previously duplicated as a map extension type (oka_core) and a typed class
/// (oka_android); consolidated here.
@immutable
class MavenCoordinate {
  const MavenCoordinate({
    required this.groupId,
    required this.artifactId,
    required this.version,
    this.packaging = 'jar',
  });

  /// Decodes from oka.yaml-style JSON/YAML maps (accepts `groupId`/`group`
  /// and `artifactId`/`artifact` aliases).
  factory MavenCoordinate.fromJson(final Object? json) {
    final map = json is Map
        ? json.cast<String, dynamic>()
        : <String, dynamic>{};
    return MavenCoordinate(
      groupId: map['groupId'] as String? ?? map['group'] as String? ?? '',
      artifactId:
          map['artifactId'] as String? ?? map['artifact'] as String? ?? '',
      version: map['version'] as String? ?? '',
      packaging: map['packaging'] as String? ??
          map['extension'] as String? ??
          'jar',
    );
  }

  /// Maven group id (e.g. `com.example`).
  final String groupId;

  /// Maven artifact id.
  final String artifactId;

  /// Maven version.
  final String version;

  /// Artifact packaging: jar | aar | pom.
  final String packaging;

  /// Parses `group:artifact:version` (packaging auto-detected via KMP
  /// suffix probing at resolve time). Returns null for malformed input.
  static MavenCoordinate? parse(final String coordinate) {
    final parts = coordinate.split(':');
    if (parts.length != 3) return null;
    if (parts.any((final p) => p.trim().isEmpty)) return null;
    return MavenCoordinate(
      groupId: parts[0].trim(),
      artifactId: parts[1].trim(),
      version: parts[2].trim(),
    );
  }

  /// Maven repository path segment: `group/path/artifact/version`.
  String get pathSegment =>
      '${groupId.replaceAll('.', '/')}/$artifactId/$version';

  /// Downloaded file name (`<artifact>-<version>.<packaging>`; pom keeps
  /// the `.pom` extension).
  String get fileName => packaging == 'pom'
      ? '$artifactId-$version.pom'
      : '$artifactId-$version.$packaging';

  /// Cache key: coordinate plus packaging.
  String get cacheKey => '$groupId:$artifactId:$version:$packaging';

  /// Full coordinate string (group:artifact:version).
  String get coordinate => '$groupId:$artifactId:$version';

  /// Encodes back to the canonical map shape (`groupId`/`artifactId`).
  Map<String, dynamic> toJson() => {
        'groupId': groupId,
        'artifactId': artifactId,
        'version': version,
        'packaging': packaging,
      };

  /// Debug string: coordinate plus packaging.
  @override
  String toString() => '$groupId:$artifactId:$version@$packaging';

  @override
  bool operator ==(final Object other) =>
      other is MavenCoordinate && other.cacheKey == cacheKey;

  /// Hash of the cache key (equality is cache-key based).
  @override
  int get hashCode => cacheKey.hashCode;
}
