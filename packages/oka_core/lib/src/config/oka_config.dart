import 'package:from_json_to_json/from_json_to_json.dart';

import 'android_config.dart';
import 'cargo_apk_config.dart';
import 'dependency.dart';
import 'flutter_config.dart';

/// Extension type that represents the main Oka configuration.
///
/// This is the root configuration object loaded from oka.yaml file.
/// It contains Android-specific settings and dependency declarations.
///
/// Uses from_json_to_json for type-safe JSON handling.
extension type const OkaConfig(Map<String, dynamic> value) {
  static const empty = OkaConfig({});

  factory OkaConfig.fromJson(dynamic json) => OkaConfig(jsonDecodeMap(json));

  /// Android build configuration
  AndroidConfig get android => AndroidConfig.fromJson(value['android']);

  /// Build variants configuration (debug, release, custom flavors)
  Map<String, dynamic> get buildVariants =>
      jsonDecodeMap(value['build_variants']);

  /// List of dependencies (Maven artifacts, local AARs, etc.)
  List<Dependency> get dependencies {
    final deps = jsonDecodeList(value['dependencies']);
    return deps.map((dynamic e) => Dependency.fromJson(e)).toList();
  }

  /// Flutter build configuration
  FlutterConfig get flutter => FlutterConfig.fromJson(value['flutter']);

  /// Cargo-apk specific configuration
  CargoApkConfig get cargoApk => CargoApkConfig.fromJson(value['cargo_apk']);

  /// Project name
  String get name => jsonDecodeString(value['name']);

  /// Signing configuration for release builds
  Map<String, dynamic> get signing => jsonDecodeMap(value['signing']);

  /// Whether to enable verbose logging
  bool get verbose => jsonDecodeBool(value['verbose']);

  /// Project version
  String get version => jsonDecodeString(value['version']);

  Map<String, dynamic> toJson() => value;
}
