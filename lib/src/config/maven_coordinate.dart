import 'package:from_json_to_json/from_json_to_json.dart';

/// Extension type that represents a Maven coordinate.
///
/// Represents a Maven artifact with group, artifact, and version
/// in the standard Maven coordinate format (group:artifact:version).
///
/// Uses from_json_to_json for type-safe JSON handling.
extension type const MavenCoordinate(Map<String, dynamic> value) {
  factory MavenCoordinate.fromJson(dynamic json) =>
      MavenCoordinate(jsonDecodeMap(json));

  /// Create from coordinate string (group:artifact:version)
  factory MavenCoordinate.parse(String coordinate) {
    final parts = coordinate.split(':');
    if (parts.length < 3) {
      return MavenCoordinate({
        'group': parts.isNotEmpty ? parts[0] : '',
        'artifact': parts.length > 1 ? parts[1] : '',
        'version': '',
      });
    }
    return MavenCoordinate({
      'group': parts[0],
      'artifact': parts[1],
      'version': parts[2],
      'classifier': parts.length > 3 ? parts[3] : '',
      'extension': parts.length > 4 ? parts[4] : 'jar',
    });
  }

  /// Maven group ID (e.g., "androidx.core")
  String get group => jsonDecodeString(value['group']);

  /// Maven artifact ID (e.g., "core-ktx")
  String get artifact => jsonDecodeString(value['artifact']);

  /// Version string (e.g., "1.10.0")
  String get version => jsonDecodeString(value['version']);

  /// Classifier (e.g., "sources", "javadoc")
  String get classifier => jsonDecodeString(value['classifier']);

  /// File extension (default: "jar", can be "aar", "pom", etc.)
  String get extension => jsonDecodeString(value['extension']).isEmpty
      ? 'jar'
      : jsonDecodeString(value['extension']);

  /// Full coordinate string (group:artifact:version)
  String get coordinate => '$group:$artifact:$version';

  /// Coordinate with classifier if present
  String get fullCoordinate =>
      classifier.isEmpty ? coordinate : '$coordinate:$classifier';

  /// Path on Maven Central (e.g., "androidx/core/core-ktx/1.10.0")
  String get mavenPath => '${group.replaceAll('.', '/')}/$artifact/$version';

  /// Filename on Maven Central (e.g., "core-ktx-1.10.0.jar")
  String get fileName => classifier.isEmpty
      ? '$artifact-$version.$extension'
      : '$artifact-$version-$classifier.$extension';

  /// Full Maven Central URL
  String get mavenCentralUrl =>
      'https://repo1.maven.org/maven2/$mavenPath/$fileName';

  /// SHA256 checksum URL
  String get sha256Url => '$mavenCentralUrl.sha256';

  /// POM file URL
  String get pomUrl =>
      'https://repo1.maven.org/maven2/$mavenPath/$artifact-$version.pom';

  /// Whether this is an AAR artifact
  bool get isAar => extension == 'aar';

  /// Whether this is a JAR artifact
  bool get isJar => extension == 'jar';

  Map<String, dynamic> toJson() => value;

  static const empty = MavenCoordinate({});
}
