import 'package:from_json_to_json/from_json_to_json.dart';

/// Extension type that represents cargo-apk specific configuration.
///
/// Contains cargo-apk build settings and Android manifest configuration
/// that cargo-apk uses to generate the APK metadata.
///
/// Uses from_json_to_json for type-safe JSON handling.
extension type const CargoApkConfig(Map<String, dynamic> value) {
  static const empty = CargoApkConfig({});

  factory CargoApkConfig.fromJson(dynamic json) =>
      CargoApkConfig(jsonDecodeMap(json));

  /// Build targets (ABIs) to include in the APK
  List<String> get buildTargets => jsonDecodeListAs<String>(value['build_targets']);

  /// Application metadata for Android manifest
  Map<String, dynamic> get application => jsonDecodeMap(value['application']);

  /// Activity metadata for Android manifest
  Map<String, dynamic> get activity => jsonDecodeMap(value['activity']);

  /// Android permissions to request
  List<String> get permissions => jsonDecodeListAs<String>(value['permissions']);

  /// Android features required by the app
  List<Map<String, dynamic>> get features {
    final features = jsonDecodeList(value['features']);
    return features.map((e) => e as Map<String, dynamic>).toList();
  }

  /// Custom Android manifest entries
  Map<String, dynamic> get manifestEntries => jsonDecodeMap(value['manifest_entries']);

  Map<String, dynamic> toJson() => value;
}
