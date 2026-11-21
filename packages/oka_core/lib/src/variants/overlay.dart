import 'package:from_json_to_json/from_json_to_json.dart';
import 'package:meta/meta.dart';

/// A service overlay a build compiles in (ADR-0055).
///
/// Overlays are the WHAT axis of the distribution matrix: the service SDK
/// layers a channel or store composes into an artifact — Google Mobile
/// Services (`gms`), the GMS-free Huawei set (`hms-free`), Steamworks, web
/// portal SDKs, store billing bindings. One platform, many overlay sets:
/// Android × {gms, hms-free, …} is the canonical case.
///
/// An overlay is a **typed, const-constructible value**, not an enum and
/// not generated code. Three contributions, each interpreted at its own
/// layer:
///
/// * [defines] — Dart defines merged into the build context by the
///   variant transform (the ADR-0014 app-config tier: non-secret,
///   compiler-baked).
/// * [excludeNativeDependencies] / [extraNativeDependencies] — generic
///   native-dependency edits, keyed by platform selector. The generalization
///   of oka_huawei's `gmsFreeOverrides` (ADR-0013): Android pipelines fold
///   the `android` entries into their fast-settings dependency resolution;
///   platforms with no interpretation ignore the fields.
/// * the [name] — the open identity channels validate against
///   (`prohibitedOverlays`/`requiredOverlays`): the Gradle `variantFilter`
///   lesson as a composition-time check, before any tool runs.
///
/// ```dart
/// const gms = Overlay(
///   name: 'gms',
///   description: 'Google Mobile Services (Play Billing, FIS)',
///   extraNativeDependencies: {
///     'android': ['com.android.billingclient:billing-ktx:7.1.1'],
///   },
/// );
/// ```
@immutable
class Overlay {
  /// Const constructor; [name] must satisfy [validateName].
  const Overlay({
    required this.name,
    this.description = '',
    this.defines = const {},
    this.excludeNativeDependencies = const {},
    this.extraNativeDependencies = const {},
  });

  /// Decodes from a JSON map (build-context serialization).
  factory Overlay.fromJson(Object? json) {
    final map = jsonDecodeMap(json);
    Map<String, List<String>> decodeListMap(Object? raw) =>
        jsonDecodeMap(raw).map(
          (key, value) => MapEntry(key, [
            for (final e in (value as List? ?? const [])) e.toString(),
          ]),
        );
    return Overlay(
      name: jsonDecodeString(map['name']),
      description: jsonDecodeString(map['description']),
      defines: jsonDecodeMap(map['defines'])
          .map((key, value) => MapEntry(key, '$value')),
      excludeNativeDependencies: decodeListMap(
        map['exclude_native_dependencies'],
      ),
      extraNativeDependencies: decodeListMap(map['extra_native_dependencies']),
    );
  }

  /// Open overlay identity, e.g. `'gms'`, `'hms-free'`, `'steamworks'`.
  /// Lowercase identifier ([validateName]) — the value channels match
  /// legality sets against.
  final String name;

  /// One-line human explanation (explain surfaces).
  final String description;

  /// Dart defines this overlay compiles in (ADR-0014 app-config tier).
  /// Merged by the variant transform: CLI defines win over overlay
  /// defines; later overlays win over earlier ones (explicit composition,
  /// ADR-0010 no-hidden-merging law).
  final Map<String, String> defines;

  /// Platform → native dependency coordinates to EXCLUDE from resolution.
  /// e.g. `{'android': ['com.android.billingclient:*']}` — the generic
  /// form of the GMS exclusion. Exact coordinate or `group:artifact:*`
  /// prefix (Android interpretation).
  final Map<String, List<String>> excludeNativeDependencies;

  /// Platform → native dependency coordinates to ADD to resolution.
  final Map<String, List<String>> extraNativeDependencies;

  /// Overlay-name pattern: lowercase identifiers (same shape as store
  /// keys and target names).
  static final RegExp namePattern = RegExp(r'^[a-z][a-z0-9_-]*$');

  /// A validation error for [candidate], or null when valid.
  static String? validateName(String candidate) {
    if (!namePattern.hasMatch(candidate)) {
      return 'invalid overlay name "$candidate": overlay names are '
          'lowercase identifiers ([a-z][a-z0-9_-]*), e.g. "gms".';
    }
    return null;
  }

  /// This overlay's validation issues (empty = valid). Pure — used by
  /// delivery composition validation.
  List<String> validate() {
    final issues = <String>[];
    final nameError = validateName(name);
    if (nameError != null) issues.add(nameError);
    for (final entry in excludeNativeDependencies.entries) {
      if (!namePattern.hasMatch(entry.key)) {
        issues.add(
          'overlay "$name": invalid platform selector '
          '"${entry.key}" in excludeNativeDependencies.',
        );
      }
    }
    for (final entry in extraNativeDependencies.entries) {
      if (!namePattern.hasMatch(entry.key)) {
        issues.add(
          'overlay "$name": invalid platform selector '
          '"${entry.key}" in extraNativeDependencies.',
        );
      }
    }
    return issues;
  }

  /// Native-dependency excludes for [platform] (exact/prefix patterns).
  List<String> excludesFor(String platform) =>
      excludeNativeDependencies[platform] ?? const [];

  /// Native-dependency additions for [platform].
  List<String> extrasFor(String platform) =>
      extraNativeDependencies[platform] ?? const [];

  /// Encodes to a JSON map (build-context serialization).
  Map<String, dynamic> toJson() => {
    'name': name,
    if (description.isNotEmpty) 'description': description,
    if (defines.isNotEmpty) 'defines': defines,
    if (excludeNativeDependencies.isNotEmpty)
      'exclude_native_dependencies': excludeNativeDependencies,
    if (extraNativeDependencies.isNotEmpty)
      'extra_native_dependencies': extraNativeDependencies,
  };

  @override
  bool operator ==(Object other) =>
      other is Overlay &&
      other.name == name &&
      other.description == description &&
      _mapsEqual(other.defines, defines) &&
      _listMapsEqual(
        other.excludeNativeDependencies,
        excludeNativeDependencies,
      ) &&
      _listMapsEqual(other.extraNativeDependencies, extraNativeDependencies);

  @override
  int get hashCode => Object.hash(
    name,
    description,
    Object.hashAll(defines.entries),
    Object.hashAll(excludeNativeDependencies.entries),
    Object.hashAll(extraNativeDependencies.entries),
  );

  static bool _mapsEqual(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  static bool _listMapsEqual(
    Map<String, List<String>> a,
    Map<String, List<String>> b,
  ) =>
      a.length == b.length &&
      a.entries.every(
        (e) => _listsEqual(b[e.key] ?? const <String>[], e.value),
      );

  static bool _listsEqual(List<String> a, List<String> b) =>
      a.length == b.length && a.indexed.every((e) => b[e.$1] == e.$2);

  /// Debug string: name plus a short contribution summary.
  @override
  String toString() {
    final extras = [
      if (defines.isNotEmpty) '${defines.length} defines',
      if (excludeNativeDependencies.isNotEmpty ||
          extraNativeDependencies.isNotEmpty)
        'native-dep overrides',
    ];
    final summary = extras.isEmpty ? '' : ', ${extras.join(', ')}';
    return 'Overlay($name$summary)';
  }
}
