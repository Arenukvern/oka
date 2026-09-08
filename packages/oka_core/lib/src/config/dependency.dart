import 'package:from_json_to_json/from_json_to_json.dart';

/// Extension type that represents a dependency declaration.
///
/// Can represent Maven artifacts, local AARs, or plugin dependencies.
/// Supports different sources: maven, local, plugin.
///
/// Uses from_json_to_json for type-safe JSON handling.
extension type const Dependency(Map<String, dynamic> value) {
  /// Decodes from a dependency entry map (maven coordinate + natives).
  factory Dependency.fromJson(final Object? json) => Dependency(jsonDecodeMap(json));

  /// Dependency name (e.g., "androidx.core:core-ktx" or "my-library")
  String get name => jsonDecodeString(value['name']);

  /// Version string (e.g., "1.10.0")
  String get version => jsonDecodeString(value['version']);

  /// Source type: "maven", "local", "plugin"
  String get source => jsonDecodeString(value['source']);

  /// Maven group ID (e.g., "androidx.core")
  String get groupId {
    final parts = name.split(':');
    return parts.isNotEmpty ? parts[0] : '';
  }

  /// Maven artifact ID (e.g., "core-ktx")
  String get artifactId {
    final parts = name.split(':');
    return parts.length > 1 ? parts[1] : name;
  }

  /// Full Maven coordinate (group:artifact:version)
  String get coordinate => '$name:$version';

  /// Local path for local dependencies
  String get path => jsonDecodeString(value['path']);

  /// Whether this is a transitive dependency
  bool get isTransitive => jsonDecodeBool(value['transitive']);

  /// Scope: compile, runtime, provided
  String get scope => jsonDecodeString(value['scope']);

  /// Exclusions for transitive dependencies
  List<String> get exclusions => jsonDecodeListAs<String>(value['exclusions']);

  /// Whether this dependency is from Maven Central
  bool get isMaven => source == 'maven';

  /// Whether this is a local file dependency
  bool get isLocal => source == 'local';

  /// Whether this comes from a Flutter plugin
  bool get isPlugin => source == 'plugin';

  /// Encodes back to the dependency entry map (identity).
  Map<String, dynamic> toJson() => value;

  static const empty = Dependency({});
}
