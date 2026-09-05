import 'package:from_json_to_json/from_json_to_json.dart';

import 'dependency.dart';

/// Extension type that represents Flutter plugin metadata.
///
/// Contains information about a Flutter plugin's Android implementation,
/// including dependencies, source directories, and native code requirements.
///
/// Uses from_json_to_json for type-safe JSON handling.
extension type const PluginMetadata(Map<String, dynamic> value) {
  factory PluginMetadata.fromJson(dynamic json) =>
      PluginMetadata(jsonDecodeMap(json));

  /// Plugin name
  String get name => jsonDecodeString(value['name']);

  /// Plugin version
  String get version => jsonDecodeString(value['version']);

  /// Path to plugin directory
  String get path => jsonDecodeString(value['path']);

  /// Android package name
  String get packageName => jsonDecodeString(value['package_name']);

  /// Plugin class name
  String get pluginClass => jsonDecodeString(value['plugin_class']);

  /// Android dependencies extracted from plugin
  List<Dependency> get dependencies {
    final deps = jsonDecodeList(value['dependencies']);
    return deps.map((dynamic e) => Dependency.fromJson(e)).toList();
  }

  /// Source directories relative to plugin android/ folder
  List<String> get sourceDirs => jsonDecodeListAs<String>(value['source_dirs']);

  /// Resource directories
  List<String> get resDirs => jsonDecodeListAs<String>(value['res_dirs']);

  /// Path to AndroidManifest.xml
  String get manifestPath => jsonDecodeString(value['manifest_path']);

  /// Minimum SDK version required by plugin
  String get minSdk => jsonDecodeString(value['min_sdk']);

  /// Whether plugin has native code (.so files)
  bool get hasNativeCode => jsonDecodeBool(value['has_native_code']);

  /// Supported ABIs for native code
  List<String> get supportedAbis =>
      jsonDecodeListAs<String>(value['supported_abis']);

  Map<String, dynamic> toJson() => value;

  static const empty = PluginMetadata({});
}
