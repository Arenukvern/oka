import 'package:meta/meta.dart';

import '../config/build_context.dart';
import '../store/store_key.dart';
import 'overlay.dart';

/// The WHAT-compiles-in bundle a delivery applies to its pipeline
/// (ADR-0055): the store key, the Flutter entrypoint, extra Dart defines,
/// and the service overlays.
///
/// A variant generalizes the per-store binding mechanism: the
/// [entrypoint] selects which binding file the app kernel compiles (each
/// entrypoint imports exactly one store's backend, so only that backend
/// ships in the AOT snapshot), the [key] names the store openly
/// ([StoreKey] — no enum), and [overlays] carry the service-SDK layers
/// (defines + native-dependency edits).
///
/// Application is a **pure [BuildContext] transform** — no tool runs, no
/// I/O:
///
/// * [entrypoint] → `targetOverride`, unless the CLI `--target` (already
///   in the context) set one — invocation wins over composition;
/// * [defines] and overlay defines → `dartDefines`, **under** the
///   existing context defines (CLI wins; later overlays win over earlier);
/// * [key] → the [okaStoreDefine] dart define — the store identity
///   reaches the compiled binary, so the app boot can verify its runtime
///   binding matches the composition (one identity end to end, no
///   two-masters drift);
/// * [overlays] → `BuildContext.overlays` for platform interpretation
///   (Android folds native-dependency edits into its fast settings).
///
/// ```dart
/// const rustore = Variant(
///   key: storeKeyRuStore,
///   entrypoint: 'lib/entrypoints/main_store_rustore.dart',
///   overlays: [hmsFree],
/// );
/// ```
@immutable
class Variant {
  /// Const constructor. Validates lazily — [validate] reports issues as
  /// data so delivery composition can aggregate them.
  const Variant({
    this.key,
    this.entrypoint = '',
    this.defines = const {},
    this.overlays = const [],
  });

  /// The open store key this variant builds for. Null = store-neutral
  /// (a delivery that composes no store identity — a landing page, a
  /// service).
  final StoreKey? key;

  /// Flutter entrypoint this variant compiles
  /// (`lib/entrypoints/main_store_rustore.dart` and friends). Empty =
  /// inherit (CLI `--target` → oka.yaml `flutter.entrypoint` →
  /// `lib/main.dart`, the standard resolution order).
  final String entrypoint;

  /// Dart defines this variant compiles in (ADR-0014 app-config tier —
  /// non-secret values only).
  final Map<String, String> defines;

  /// Service overlays compiled into this variant, in composition order.
  /// Later overlays' defines win over earlier ones (no hidden merging,
  /// ADR-0010).
  final List<Overlay> overlays;

  /// Overlay names in this variant (the set channel legality validates
  /// against).
  Set<String> get overlayNames => {for (final o in overlays) o.name};

  /// All overlay defines folded in composition order (later wins).
  Map<String, String> get overlayDefines => {
    for (final o in overlays) ...o.defines,
  };

  /// Validation issues (empty = valid): key/overlay names, entrypoint
  /// shape, overlay self-validation. Pure data — aggregated by delivery
  /// composition validation.
  List<String> validate() {
    final issues = <String>[];
    final keyError = key?.validateError;
    if (keyError != null) issues.add('variant: $keyError');
    if (entrypoint.isNotEmpty) {
      if (entrypoint.startsWith('/') || entrypoint.contains('..')) {
        issues.add(
          'variant entrypoint "$entrypoint" must be a project-relative '
          'path without ".." segments, e.g. '
          '"lib/entrypoints/main_store_rustore.dart".',
        );
      }
      if (!entrypoint.endsWith('.dart')) {
        issues.add('variant entrypoint "$entrypoint" must be a .dart file.');
      }
    }
    for (final overlay in overlays) {
      issues.addAll(
        overlay.validate().map((issue) => 'variant overlay: $issue'),
      );
    }
    return issues;
  }

  /// The pure [BuildContext] transform (see the class doc for the merge
  /// order). Returns [ctx] unchanged when this variant carries nothing.
  BuildContext applyTo(BuildContext ctx) {
    final hasDefines = defines.isNotEmpty || overlays.isNotEmpty;
    final hasOverlays = overlays.isNotEmpty;
    if (key == null && entrypoint.isEmpty && !hasDefines && !hasOverlays) {
      return ctx;
    }
    return ctx.copyWith(
      targetOverride: ctx.targetOverride.isNotEmpty
          ? ctx.targetOverride
          : entrypoint,
      dartDefines: hasDefines || key != null
          ? {
              ...defines,
              ...overlayDefines,
              if (key != null) okaStoreDefine: key!.name,
              ...ctx.dartDefines,
            }
          : ctx.dartDefines,
      overlays: hasOverlays ? List.unmodifiable(overlays) : ctx.overlays,
    );
  }

  /// Explain lines for `oka explain --targets` (pure).
  List<String> explainLines() => [
    if (key != null) 'variant store: ${key!.name} (baked as $okaStoreDefine)',
    if (entrypoint.isNotEmpty) 'variant entrypoint: $entrypoint',
    if (defines.isNotEmpty)
      'variant defines: ${defines.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
    for (final o in overlays)
      'variant overlay: ${o.name}${o.description.isEmpty ? '' : ' — ${o.description}'}',
  ];

  @override
  bool operator ==(Object other) =>
      other is Variant &&
      other.key == key &&
      other.entrypoint == entrypoint &&
      _mapsEqual(other.defines, defines) &&
      _listsEqual(other.overlays, overlays);

  @override
  int get hashCode => Object.hash(
    key,
    entrypoint,
    Object.hashAll(defines.entries),
    Object.hashAll(overlays),
  );

  /// Debug string: key + entrypoint + overlay count.
  @override
  String toString() =>
      'Variant(${key?.name ?? 'store-neutral'}'
      '${entrypoint.isEmpty ? '' : ', ${entrypoint.split('/').last}'}'
      '${overlays.isEmpty ? '' : ', ${overlays.length} overlays'})';

  static bool _mapsEqual(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  static bool _listsEqual(List<Overlay> a, List<Overlay> b) =>
      a.length == b.length && a.indexed.every((e) => b[e.$1] == e.$2);
}
