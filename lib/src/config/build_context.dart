import 'package:from_json_to_json/from_json_to_json.dart';

import 'oka_config.dart';

/// Build mode enumeration
enum BuildMode {
  debug,
  release,
  profile;

  bool get isDebug => this == BuildMode.debug;
  bool get isRelease => this == BuildMode.release;
  bool get isProfile => this == BuildMode.profile;
}

/// Extension type that represents the build context.
///
/// Contains all state and configuration needed during the build process.
/// Includes paths, build mode, configuration, and artifact tracking.
///
/// Uses from_json_to_json for type-safe JSON handling.
extension type const BuildContext(Map<String, dynamic> value) {
  factory BuildContext.fromJson(dynamic json) =>
      BuildContext(jsonDecodeMap(json));

  /// Project root path
  String get projectPath => jsonDecodeString(value['project_path']);

  /// Build output directory
  String get buildDir => jsonDecodeString(value['build_dir']);

  /// Build mode (debug, release, profile)
  BuildMode get mode {
    final modeStr = jsonDecodeString(value['mode']);
    switch (modeStr) {
      case 'release':
        return BuildMode.release;
      case 'profile':
        return BuildMode.profile;
      default:
        return BuildMode.debug;
    }
  }

  /// Oka configuration from oka.yaml
  OkaConfig get config => OkaConfig.fromJson(value['config']);

  /// Cache directory for incremental builds
  String get cacheDir => jsonDecodeString(value['cache_dir']);

  /// Temporary directory for intermediate build artifacts
  String get tempDir => jsonDecodeString(value['temp_dir']);

  /// Flutter SDK path
  String get flutterSdkPath => jsonDecodeString(value['flutter_sdk_path']);

  /// Android SDK path
  String get androidSdkPath => jsonDecodeString(value['android_sdk_path']);

  /// Build timestamp
  DateTime? get buildTimestamp => dateTimeFromMilisecondsSinceEpoch(
      jsonDecodeInt(value['build_timestamp']));

  /// Whether verbose logging is enabled
  bool get verbose => jsonDecodeBool(value['verbose']);

  /// Build flavor (if using flavors)
  String get flavor => jsonDecodeString(value['flavor']);

  /// Target device ABI
  String get targetAbi => jsonDecodeString(value['target_abi']);

  /// Whether to build Android App Bundle instead of APK
  bool get buildAab => jsonDecodeBool(value['build_aab']);

  Map<String, dynamic> toJson() => value;

  static const empty = BuildContext({});
}

/// Extension type for build artifacts
extension type const BuildArtifact(Map<String, dynamic> value) {
  factory BuildArtifact.fromJson(dynamic json) =>
      BuildArtifact(jsonDecodeMap(json));

  /// Output file path (APK or AAB)
  String get apkPath => jsonDecodeString(value['apk_path']); // Keep for backward compatibility

  /// Output file path (APK or AAB)
  String get outputPath => jsonDecodeString(value['apk_path']);

  /// APK file size in bytes
  int get size => jsonDecodeInt(value['size']);

  /// Build duration in milliseconds
  int get buildDuration => jsonDecodeInt(value['build_duration']);

  /// Build timestamp
  DateTime? get timestamp =>
      dateTimeFromMilisecondsSinceEpoch(jsonDecodeInt(value['timestamp']));

  /// Whether this is a successful build
  bool get success => jsonDecodeBool(value['success']);

  /// Error message if build failed
  String get error => jsonDecodeString(value['error']);

  Map<String, dynamic> toJson() => value;

  static const empty = BuildArtifact({});
}
