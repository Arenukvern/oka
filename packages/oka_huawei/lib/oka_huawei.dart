/// The Huawei DEVICE platform package for oka (ADR-0055, ADR-0056).
///
/// Platforms and stores are different axes, and the line between them is
/// thin but real: a Huawei DEVICE is a platform — a runtime that ships
/// without Google Play Services. A store (AppGallery, RuStore, Google
/// Play) is a distribution channel — a Huawei device carries AppGallery,
/// RuStore, and sideloaded APKs alike. This package therefore holds the
/// PLATFORM half only: the GMS-excluding Android build composition
/// ([HuaweiBuildVariant]). The store half moved to its own packages —
/// `oka_app_gallery` (AppGallery Connect channel + key) and `oka_rustore`
/// (RuStore channel + key).
///
/// ## The GMS-excluding build variant
///
/// Huawei AppGallery builds ship **without Google Play Services**: a GMS
/// coordinate in `extraDeps` would either fail at runtime on GMS-free
/// devices or drag the Play dependency graph into a non-Play artifact.
/// [HuaweiBuildVariant] is the composition-time half of that posture:
///
/// * [HuaweiBuildVariant.gmsFreeOverrides] filters `extraDeps`
///   ([PipelineOverrides.extraDeps]) through `isGmsCoordinate` (the
///   `oka_android` seam) — GMS coordinates are excluded, everything else
///   passes through unchanged.
/// * [HuaweiBuildVariant.excludedGmsDeps] names exactly what was dropped —
///   inspectable data, printed by diagnostics.
/// * Composition-time safety: any step that *requires* a
///   [gmsDependencyArtifact] (e.g. Play Billing) fails the standard
///   artifact validator ([Pipeline.validate]) in a pipeline composed from
///   this variant — **before any tool runs**, because the GMS-providing
///   step ([GmsDependencyProviderStep]) is absent by construction.
///
/// ```dart
/// import 'package:oka_huawei/oka_huawei.dart';
///
/// const variant = HuaweiBuildVariant(
///   android: AndroidBuild(packageName: 'dev.example.app'),
///   overrides: PipelineOverrides(
///     extraDeps: [
///       'androidx.core:core-ktx:1.13.1',              // kept
///       'com.android.billingclient:billing-ktx:7.0.0', // excluded (GMS)
///     ],
///   ),
/// );
///
/// final pipeline = AndroidPipeline(
///   config: variant.android,
///   overrides: variant.gmsFreeOverrides,
/// );
/// ```
///
/// Store channels declare their platform requirements at composition time
/// (`requiredOverlays`/`prohibitedOverlays`): the AppGallery channel
/// prohibits the `gms` overlay; Play requires it. The platform never
/// names a store.
///
/// See also:
///
/// * `oka_core` — the delivery matrix ([Delivery], [Variant], overlays)
///   and ADR-0056 for the store/platform line.
/// * `oka_app_gallery` — the AppGallery STORE package (publish channel).
/// * `oka_android` — `foldOverlayDependencies`, the generic
///   overlay-native-dependency folding this variant predates.
library;

export 'src/gms_variant.dart';
