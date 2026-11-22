import 'package:meta/meta.dart';
import 'package:oka_android/oka_android.dart';

/// The GMS-excluding Android build composition for Huawei devices
/// (ADR-0056: the PLATFORM half — a Huawei device ships without Google
/// Play Services; the store half lives in `oka_app_gallery`/`oka_rustore`).
///
/// A GMS coordinate in `extraDeps` would either fail at runtime on
/// GMS-free devices or drag the Play dependency graph into a
/// non-Play artifact. This typed value carries the platform posture:
///
/// * [gmsFreeOverrides] filters `extraDeps` ([PipelineOverrides.extraDeps])
///   through `isGmsCoordinate` (oka_android seam) — GMS coordinates are
///   excluded, everything else passes through unchanged.
/// * [excludedGmsDeps] names exactly what was dropped — inspectable data,
///   printed by diagnostics.
/// * Composition-time safety: any step that *requires* a
///   [gmsDependencyArtifact] (e.g. Play Billing) fails the standard
///   artifact validator ([Pipeline.validate]) in a pipeline composed from
///   this variant — **before any tool runs**, because the GMS-providing
///   step ([GmsDependencyProviderStep]) is absent by construction.
///
/// The overrides live in [HuaweiBuildVariant.overrides] and are read via
/// `overrides.extraDeps` (or, in compositions, [gmsFreeOverrides]).
///
/// ```dart
/// final pipeline = AndroidPipeline(
///   config: variant.android,
///   overrides: variant.gmsFreeOverrides,
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

  /// The `extraDeps` list of [overrides] with GMS-provided coordinates
  /// removed.
  List<String> get gmsFreeExtraDeps =>
      splitGmsDependencies(overrides.extraDeps).other;

  /// Exactly the coordinates the exclusion dropped (inspectable data).
  List<String> get excludedGmsDeps =>
      splitGmsDependencies(overrides.extraDeps).gms;

  /// [overrides] with `extraDeps` replaced by [gmsFreeExtraDeps] — the
  /// composition a Huawei artifact is built from.
  PipelineOverrides get gmsFreeOverrides =>
      overrides.copyWith(extraDeps: gmsFreeExtraDeps);

  /// Debug string: package name plus the exclusion count.
  @override
  String toString() =>
      'HuaweiBuildVariant(${android.packageName}, '
      'gms-excluded: ${excludedGmsDeps.length} dep(s))';

  /// Field-wise equality.
  @override
  bool operator ==(Object other) =>
      other is HuaweiBuildVariant &&
      other.android == android &&
      other.overrides == overrides;

  /// Hash over both fields.
  @override
  int get hashCode => Object.hash(android, overrides);
}
