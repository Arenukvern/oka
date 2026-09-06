import 'package:from_json_to_json/from_json_to_json.dart';

/// Extension type that represents Flutter-specific configuration.
///
/// Contains Flutter build settings such as entrypoint, assets,
/// and build optimization options.
///
/// Uses from_json_to_json for type-safe JSON handling.
extension type const FlutterConfig(Map<String, dynamic> value) {

  factory FlutterConfig.fromJson(final Object? json) =>
      FlutterConfig(jsonDecodeMap(json));
  static const empty = FlutterConfig({});

  /// Asset directories to include in the bundle
  List<String> get assets => jsonDecodeListAs<String>(value['assets']);

  /// Additional arguments to pass to flutter build commands
  List<String> get buildArgs => jsonDecodeListAs<String>(value['build_args']);

  /// Build mode for Flutter compilation (debug, profile, release)
  String get buildMode => jsonDecodeString(value['build_mode']);

  /// Whether to use Flutter's deferred components feature
  bool get deferredComponents => jsonDecodeBool(value['deferred_components']);

  /// Whether to enable Flutter's hot reload support in development builds
  bool get enableHotReload => jsonDecodeBool(value['enable_hot_reload']);

  /// Path to custom Flutter engine artifacts (advanced usage)
  String? get enginePath {
    final path = jsonDecodeString(value['engine_path']);
    return path.isEmpty ? null : path;
  }

  /// Custom Flutter engine version to use (if not using system default)
  String? get engineVersion {
    final version = jsonDecodeString(value['engine_version']);
    return version.isEmpty ? null : version;
  }

  /// Main entrypoint file for the Flutter app (e.g., "lib/main.dart")
  String get entrypoint => jsonDecodeString(value['entrypoint']);

  /// Flutter plugins to include (auto-detected if empty)
  List<String> get plugins => jsonDecodeListAs<String>(value['plugins']);

  /// Target platform for Flutter build (android, ios, etc.)
  String get targetPlatform => jsonDecodeString(value['target_platform']);

  /// Whether to enable Flutter's tree shaking for smaller APKs
  bool get treeShakeIcons => jsonDecodeBool(value['tree_shake_icons']);

  Map<String, dynamic> toJson() => value;
}
