import 'package:from_json_to_json/from_json_to_json.dart';

/// Extension type that represents the result of manifest merging.
///
/// Contains the merged AndroidManifest.xml content and metadata
/// about the merge operation.
///
/// Uses from_json_to_json for type-safe JSON handling.
extension type const ManifestMergeResult(Map<String, dynamic> value) {
  factory ManifestMergeResult.fromJson(final Object? json) =>
      ManifestMergeResult(jsonDecodeMap(json));

  /// Merged manifest XML content
  String get mergedXml => jsonDecodeString(value['merged_xml']);

  /// Whether merge was successful
  bool get success => jsonDecodeBool(value['success']);

  /// Error messages if merge failed
  List<String> get errors => jsonDecodeListAs<String>(value['errors']);

  /// Warning messages from merge
  List<String> get warnings => jsonDecodeListAs<String>(value['warnings']);

  /// List of source manifests that were merged
  List<String> get sourcePaths =>
      jsonDecodeListAs<String>(value['source_paths']);

  /// Merge strategy used (ai, manual, default)
  String get mergeStrategy => jsonDecodeString(value['merge_strategy']);

  /// Timestamp of merge operation
  DateTime? get timestamp =>
      dateTimeFromMillisecondsSinceEpoch(jsonDecodeInt(value['timestamp']));

  /// Whether merge result was cached
  bool get fromCache => jsonDecodeBool(value['from_cache']);

  Map<String, dynamic> toJson() => value;

  static const empty = ManifestMergeResult({});
}

/// Merge rules for AI-based manifest merging
extension type const MergeRules(Map<String, dynamic> value) {
  factory MergeRules.fromJson(final Object? json) => MergeRules(jsonDecodeMap(json));

  /// Priority order for conflicting attributes
  String get priorityStrategy => jsonDecodeString(value['priority_strategy']);

  /// Whether to merge permissions automatically
  bool get mergePermissions => jsonDecodeBool(value['merge_permissions']);

  /// Whether to merge application attributes
  bool get mergeApplicationAttrs =>
      jsonDecodeBool(value['merge_application_attrs']);

  /// Custom rules for specific elements
  Map<String, String> get customRules =>
      jsonDecodeMapAs<String, String>(value['custom_rules']);

  Map<String, dynamic> toJson() => value;

  static const empty = MergeRules({});
}
