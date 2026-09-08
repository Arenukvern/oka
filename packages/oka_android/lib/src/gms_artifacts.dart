/// GMS-dependency artifact seam (ADR-0013 two-axis law; ADR-0014 P2).
///
/// Distribution targets that *exclude* Google Play Services (GMS) — Huawei
/// AppGallery being the reference case — must still be provable at
/// composition time when a step depends on a GMS-provided artifact. This
/// seam gives GMS-provided dependencies the same typed-artifact identity as
/// every other pipeline input, so the **existing** artifact validator
/// ([Pipeline.validate]) rejects a GMS-dependent step in a GMS-excluded
/// composition *before any tool runs* — no new validator, no new mechanism:
///
/// ```dart
/// // A step that needs Play Billing (GMS-provided):
/// class PlayBillingStep extends BuildStep {
///   static final billing =
///       gmsDependencyArtifact('com.android.billingclient:billing-ktx');
///
///   @override
///   Set<Artifact<Object>> get requires => {billing};
///   // ...
/// }
///
/// // In a GMS-excluded variant no step provides that artifact:
/// final pipeline = Pipeline([PlayBillingStep()]);
/// pipeline.validate(); // → names 'gms-dep:com.android.billingclient:…'
/// ```
///
/// This file is purely additive: it declares no behavior change in any
/// existing step — the Android pipeline is untouched unless a composition
/// *opts in* by including [GmsDependencyProviderStep].
library;

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:oka_core/oka_core.dart';

/// Artifact-id prefix marking a GMS-provided dependency.
///
/// Ids take the form `gms-dep:<coordinate>` where `<coordinate>` is the
/// Maven coordinate **without** version (e.g.
/// `gms-dep:com.android.billingclient:billing-ktx`) — versions resolve at
/// dependency time and must not be part of the composition-time contract.
const String gmsDependencyArtifactPrefix = 'gms-dep:';

/// The artifact id for a GMS-provided [coordinate] (no version).
String gmsDependencyArtifactId(final String coordinate) =>
    '$gmsDependencyArtifactPrefix$coordinate';

/// Whether [id] is a GMS-dependency artifact id.
bool isGmsDependencyArtifactId(final String id) =>
    id.startsWith(gmsDependencyArtifactPrefix);

/// A typed artifact handle on a resolved GMS-provided dependency.
///
/// Identity is the coordinate without version, so a step requiring
/// Play Billing composes against whatever version the dependency layer
/// resolved.
Artifact<String> gmsDependencyArtifact(final String coordinate) =>
    Artifact<String>(
      gmsDependencyArtifactId(coordinate),
      description: 'GMS-provided dependency $coordinate',
    );

/// Maven group prefixes whose artifacts are provided by Google Play
/// Services (GMS) and therefore excluded from a GMS-free build variant.
///
/// Data, not control flow — printed by diagnostics and unit-tested.
const List<String> gmsGroupPrefixes = [
  'com.google.android.gms',
  'com.google.android.play',
  'com.google.android.ads',
  'com.google.firebase',
  'com.android.billingclient',
];

/// Whether a Maven [coordinate] (`group:artifact:version`) is provided by
/// GMS — i.e. must be excluded from a GMS-free variant.
///
/// Malformed coordinates (no `:`) are never classified as GMS: the
/// dependency layer reports them.
bool isGmsCoordinate(final String coordinate) {
  final group = coordinate.split(':').first;
  for (final prefix in gmsGroupPrefixes) {
    if (group == prefix || group.startsWith('$prefix.')) return true;
  }
  return false;
}

/// Splits [coordinates] into the GMS-provided ones and the rest — the
/// classification a GMS-exclusion variant applies to `extraDeps`.
({List<String> gms, List<String> other}) splitGmsDependencies(
  final Iterable<String> coordinates,
) {
  final gms = <String>[];
  final other = <String>[];
  for (final c in coordinates) {
    (isGmsCoordinate(c) ? gms : other).add(c);
  }
  return (gms: List.unmodifiable(gms), other: List.unmodifiable(other));
}

/// A step that *provides* GMS-dependency artifacts for a composition that
/// **includes** GMS (e.g. a Play distribution target).
///
/// Pure declaration + existence check: the constructor takes the resolved
/// coordinate → jar/aar paths (produced by the dependency layer in a real
/// build); `run` verifies each file exists and records the paths in state.
/// It performs no resolution and no download — the dependency-resolve step
/// upstream owns that.
///
/// A GMS-**excluded** variant simply omits this step. Any step requiring a
/// [gmsDependencyArtifact] then fails [Pipeline.validate] at composition
/// time — before any tool runs (ADR-0013 law).
class GmsDependencyProviderStep extends BuildStep {
  /// [resolvedPaths] maps a Maven coordinate (no version) to the resolved
  /// jar/aar file path for each GMS dependency the composition includes.
  GmsDependencyProviderStep({required this.resolvedPaths});
  final Map<String, String> resolvedPaths;

  @override
  String get name => 'gms-dependency-provider';

  @override
  Set<Artifact<Object>> get provides => {
        for (final coordinate in resolvedPaths.keys) gmsDependencyArtifact(coordinate),
      };

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    for (final entry in resolvedPaths.entries) {
      final file = entry.value;
      if (!await isReadableFile(file)) {
        return StepResult.failure(
          'GMS dependency "${entry.key}" resolved to a missing file: $file — '
          'fix the dependency resolution step upstream or drop the '
          'GMS dependency from this variant',
        );
      }
      state[gmsDependencyArtifactId(entry.key)] = file;
    }
    return StepResult.success({
      'gms-dependencies': resolvedPaths.keys.join(', '),
    });
  }

  /// Existence check seam (injected in tests; real builds stat the file).
  @visibleForTesting
  Future<bool> isReadableFile(final String path) async =>
      File(path).existsSync();
}
