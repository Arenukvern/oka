import 'package:from_json_to_json/from_json_to_json.dart';

/// Extension type that represents Android build configuration.
///
/// Contains Android-specific settings such as SDK versions,
/// package name, and build tool configurations.
///
/// Uses from_json_to_json for type-safe JSON handling.
extension type const AndroidConfig(Map<String, dynamic> value) {
  factory AndroidConfig.fromJson(dynamic json) =>
      AndroidConfig(jsonDecodeMap(json));

  /// Compile SDK version (e.g., "34")
  String get compileSdk => jsonDecodeString(value['compile_sdk']);

  /// Minimum SDK version (e.g., "21")
  String get minSdk => jsonDecodeString(value['min_sdk']);

  /// Target SDK version (e.g., "34")
  String get targetSdk => jsonDecodeString(value['target_sdk']);

  /// Android package name (e.g., "com.example.app")
  String get packageName => jsonDecodeString(value['package_name']);

  /// Application ID (defaults to package name if not specified)
  String get applicationId => jsonDecodeString(value['application_id']).isEmpty
      ? packageName
      : jsonDecodeString(value['application_id']);

  /// Version code for the APK
  int get versionCode => jsonDecodeInt(value['version_code']);

  /// Version name for the APK
  String get versionName => jsonDecodeString(value['version_name']);

  /// Source directories for Java/Kotlin code
  List<String> get sourceDirs => jsonDecodeListAs<String>(value['source_dirs']);

  /// Resource directories
  List<String> get resDirs => jsonDecodeListAs<String>(value['res_dirs']);

  /// Whether to enable ProGuard/R8 optimization
  bool get enableOptimization => jsonDecodeBool(value['enable_optimization']);

  /// ProGuard rules files
  List<String> get proguardFiles =>
      jsonDecodeListAs<String>(value['proguard_files']);

  /// Supported ABIs (arm64-v8a, armeabi-v7a, x86_64, etc.)
  List<String> get abis => jsonDecodeListAs<String>(value['abis']);

  /// Java source/target compatibility version (defaults to 11)
  int get javaVersion {
    final version = jsonDecodeInt(value['java_version']);
    return version == 0 ? 11 : version;
  }

  Map<String, dynamic> toJson() => value;

  static const empty = AndroidConfig({});
}
