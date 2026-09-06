
import 'pipeline/steps/asset_steps.dart' show DeeplinkConfig;

/// Typed Android manifest specification rendered by host-codegen (ADR-0006).
///
/// This is the G5 replacement: instead of growing YAML config fields for
/// manifest surface, the manifest is a **typed value**. Hooks and
/// Dart-composed pipelines override it with [copyWith]; `oka.yaml`
/// (`android.manifest:`) is one source among several.
///
/// Rendering is deterministic (pure function in `host_codegen.dart`).
class ManifestSpec {

  const ManifestSpec({
    this.permissions = const ['android.permission.INTERNET'],
    this.applicationAttributes = const {},
    this.applicationMetaData = const [],
    this.activityAttributes = const {},
    this.deeplinks = const [],
    this.debuggable = true,
    this.extractNativeLibs = true,
    this.flutterDeeplinking = false,
    this.cleartextTraffic,
  });

  /// Parses `oka.yaml` `android.manifest:` section.
  ///
  /// ```yaml
  /// android:
  ///   manifest:
  ///     permissions: [android.permission.INTERNET, android.permission.CAMERA]
  ///     cleartext_traffic: true
  ///     application_attributes: {android:hardwareAccelerated: "true"}
  ///     activity_attributes: {android:launchMode: singleTask}
  ///     meta_data:
  ///       - name: flutter_deeplinking_enabled
  ///         value: "true"
  /// ```
  factory ManifestSpec.fromYamlMap(final Map<dynamic, dynamic> map) {
    final perms = map['permissions'];
    final appAttrs = map['application_attributes'];
    final actAttrs = map['activity_attributes'];
    final metaData = map['meta_data'];
    final links = map['deeplinks'];
    return ManifestSpec(
      permissions: perms is List
          ? perms.map((final e) => e.toString()).toList(growable: false)
          : const [],
      applicationAttributes: appAttrs is Map<dynamic, dynamic>
          ? appAttrs.map((final k, final v) => MapEntry(k.toString(), v.toString()))
          : const {},
      activityAttributes: actAttrs is Map<dynamic, dynamic>
          ? actAttrs.map((final k, final v) => MapEntry(k.toString(), v.toString()))
          : const {},
      applicationMetaData: metaData is List
          ? metaData.whereType<Map<dynamic, dynamic>>().map(MetaDataSpec.fromMap).toList(
              growable: false,
            )
          : const [],
      deeplinks: links is List ? DeeplinkConfig.parse(links) : const [],
      cleartextTraffic:
          map['cleartext_traffic'] is bool
          ? map['cleartext_traffic'] as bool
          : null,
      debuggable: map['debuggable'] is! bool || map['debuggable'] as bool,
      extractNativeLibs: map['extract_native_libs'] is! bool || map['extract_native_libs'] as bool,
    );
  }
  /// `uses-permission` entries (full names, e.g.
  /// `android.permission.CAMERA`).
  final List<String> permissions;

  /// Extra `<application>` XML attributes (passthrough), e.g.
  /// `{'android:usesCleartextTraffic': 'true'}`.
  final Map<String, String> applicationAttributes;

  /// `<meta-data>` entries under `<application>`.
  final List<MetaDataSpec> applicationMetaData;

  /// Extra `<activity>` XML attributes (passthrough), e.g.
  /// `{'android:launchMode': 'singleTask'}`.
  final Map<String, String> activityAttributes;

  /// Deeplink intent-filters rendered with `autoVerify` where applicable.
  final List<DeeplinkConfig> deeplinks;

  /// `android:debuggable` on `<application>`.
  final bool debuggable;

  /// `android:extractNativeLibs` on `<application>`.
  final bool extractNativeLibs;

  /// Enables `flutter_deeplinking_enabled` meta-data (Flutter v2 embedding).
  final bool flutterDeeplinking;

  /// `android:usesCleartextTraffic` (null = attribute omitted).
  final bool? cleartextTraffic;

  ManifestSpec copyWith({
    final List<String>? permissions,
    final Map<String, String>? applicationAttributes,
    final List<MetaDataSpec>? applicationMetaData,
    final Map<String, String>? activityAttributes,
    final List<DeeplinkConfig>? deeplinks,
    final bool? debuggable,
    final bool? extractNativeLibs,
    final bool? flutterDeeplinking,
    final bool? cleartextTraffic,
  }) => ManifestSpec(
    permissions: permissions ?? this.permissions,
    applicationAttributes: applicationAttributes ?? this.applicationAttributes,
    applicationMetaData: applicationMetaData ?? this.applicationMetaData,
    activityAttributes: activityAttributes ?? this.activityAttributes,
    deeplinks: deeplinks ?? this.deeplinks,
    debuggable: debuggable ?? this.debuggable,
    extractNativeLibs: extractNativeLibs ?? this.extractNativeLibs,
    flutterDeeplinking: flutterDeeplinking ?? this.flutterDeeplinking,
    cleartextTraffic: cleartextTraffic ?? this.cleartextTraffic,
  );
}

/// A `<meta-data android:name="…">` entry: either `android:value` or
/// `android:resource`.
class MetaDataSpec {

  const MetaDataSpec({required this.name, this.value, this.resource});

  factory MetaDataSpec.fromMap(final Map<dynamic, dynamic> map) => MetaDataSpec(
    name: map['name'].toString(),
    value: map['value']?.toString(),
    resource: map['resource']?.toString(),
  );
  final String name;

  /// Literal value → `android:value="…"`.
  final String? value;

  /// Resource reference → `android:resource="…"` (e.g. `@style/NormalTheme`).
  final String? resource;
}

/// Common permission name constants for typed composition.
abstract final class AndroidPermission {
  static const internet = 'android.permission.INTERNET';
  static const accessNetworkState = 'android.permission.ACCESS_NETWORK_STATE';
  static const camera = 'android.permission.CAMERA';
}
