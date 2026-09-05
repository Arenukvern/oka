/// A Maven coordinate — the single canonical typed value (ADR-0006/0007).
///
/// Previously duplicated as a map extension type (oka_core) and a typed class
/// (oka_android); consolidated here.
class MavenCoordinate {
  final String groupId;
  final String artifactId;
  final String version;
  final String packaging; // jar | aar | pom

  const MavenCoordinate({
    required this.groupId,
    required this.artifactId,
    required this.version,
    this.packaging = 'jar',
  });

  factory MavenCoordinate.fromJson(dynamic json) {
    final map = (json as Map).cast<String, dynamic>();
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

  /// Parses `group:artifact:version` (packaging auto-detected via KMP
  /// suffix probing at resolve time). Returns null for malformed input.
  static MavenCoordinate? parse(String coordinate) {
    final parts = coordinate.split(':');
    if (parts.length != 3) return null;
    if (parts.any((p) => p.trim().isEmpty)) return null;
    return MavenCoordinate(
      groupId: parts[0].trim(),
      artifactId: parts[1].trim(),
      version: parts[2].trim(),
    );
  }

  String get pathSegment =>
      '${groupId.replaceAll('.', '/')}/$artifactId/$version';

  String get fileName => packaging == 'pom'
      ? '$artifactId-$version.pom'
      : '$artifactId-$version.$packaging';

  String get cacheKey => '$groupId:$artifactId:$version:$packaging';

  /// Full coordinate string (group:artifact:version).
  String get coordinate => '$groupId:$artifactId:$version';

  Map<String, dynamic> toJson() => {
        'groupId': groupId,
        'artifactId': artifactId,
        'version': version,
        'packaging': packaging,
      };

  @override
  String toString() => '$groupId:$artifactId:$version@$packaging';

  @override
  bool operator ==(Object other) =>
      other is MavenCoordinate && other.cacheKey == cacheKey;

  @override
  int get hashCode => cacheKey.hashCode;
}
