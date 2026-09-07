import 'package:meta/meta.dart';
import 'package:oka_android/oka_android.dart';

/// The GMS-excluding Android build variant behind the Huawei target
/// (ADR-0013 two-axis law: a store target = a build-variant composition
/// plus a publish tail — never a forked pipeline).
///
/// Huawei AppGallery builds ship **without Google Play Services**: a GMS
/// coordinate in `extraDeps` would either fail at runtime on
/// GMS-free devices or drag the Play dependency graph into a
/// non-Play artifact. This typed value is the composition-time half of the
/// target:
///
/// * [gmsFreeOverrides] filters [PipelineOverrides.extraDeps] through
///   `isGmsCoordinate` (oka_android seam) — GMS coordinates are excluded,
///   everything else passes through unchanged.
/// * [excludedGmsDeps] names exactly what was dropped — inspectable data,
///   printed by diagnostics.
/// * Composition-time safety: any step that *requires* a
///   [gmsDependencyArtifact] (e.g. Play Billing) fails the standard
///   artifact validator ([Pipeline.validate]) in a pipeline composed from
///   this variant — **before any tool runs**, because the GMS-providing
///   step ([GmsDependencyProviderStep]) is absent by construction.
///
/// ```dart
/// const target = HuaweiPublishTarget(
///   variant: HuaweiBuildVariant(
///     android: AndroidBuild(packageName: 'dev.example.app'),
///     overrides: PipelineOverrides(
///       extraDeps: [
///         'androidx.core:core-ktx:1.13.1',            // kept
///         'com.android.billingclient:billing-ktx:7.0.0', // excluded (GMS)
///       ],
///     ),
///   ),
/// );
/// ```
@immutable
class HuaweiBuildVariant {
  const HuaweiBuildVariant({
    this.android = const AndroidBuild(),
    this.overrides = const PipelineOverrides(),
  });

  /// The Android base config (identity, SDK levels, ABIs, …).
  final AndroidBuild android;

  /// Packaging fast-settings, interpreted with the GMS exclusion applied —
  /// read [gmsFreeOverrides] when composing a pipeline.
  final PipelineOverrides overrides;

  /// [overrides.extraDeps] with GMS-provided coordinates removed.
  List<String> get gmsFreeExtraDeps => splitGmsDependencies(
        overrides.extraDeps,
      ).other;

  /// Exactly the coordinates the exclusion dropped (inspectable data).
  List<String> get excludedGmsDeps =>
      splitGmsDependencies(overrides.extraDeps).gms;

  /// [overrides] with `extraDeps` replaced by [gmsFreeExtraDeps] — the
  /// composition a Huawei artifact is built from.
  PipelineOverrides get gmsFreeOverrides =>
      overrides.copyWith(extraDeps: gmsFreeExtraDeps);

  @override
  String toString() => 'HuaweiBuildVariant(${android.packageName}, '
      'gms-excluded: ${excludedGmsDeps.length} dep(s))';

  @override
  bool operator ==(final Object other) =>
      other is HuaweiBuildVariant &&
      other.android == android &&
      other.overrides == overrides;

  @override
  int get hashCode => Object.hash(android, overrides);
}
