import 'package:oka_core/oka_core.dart';

import 'pipeline_overrides.dart';

/// Folds a build context's overlay native-dependency edits into Android
/// fast settings (ADR-0055).
///
/// Overlays carry the generic, platform-keyed dependency edits
/// ([Overlay.excludeNativeDependencies] / [Overlay.extraNativeDependencies]);
/// this is the Android interpretation: `android` entries are folded into
/// [PipelineOverrides.extraDeps] — excludes filtered first (exact
/// coordinate or `group:artifact:*` prefix), additions appended. This
/// generalizes oka_huawei's `gmsFreeOverrides` (ADR-0013): any overlay
/// can exclude any coordinate pattern, not only GMS.
///
/// Pure data transform — dependency resolution itself stays in the
/// steps; empty overlay edits return [overrides] untouched.
PipelineOverrides foldOverlayDependencies(
  BuildContext ctx,
  PipelineOverrides overrides,
) {
  final excludes = <String>[
    for (final overlay in ctx.overlays) ...overlay.excludesFor('android'),
  ];
  final extras = <String>[
    for (final overlay in ctx.overlays) ...overlay.extrasFor('android'),
  ];
  if (excludes.isEmpty && extras.isEmpty) return overrides;
  final kept = <String>[];
  final dropped = <String>[];
  for (final dep in overrides.extraDeps) {
    (matchesDependencyExclusion(dep, excludes) ? dropped : kept).add(dep);
  }
  if (ctx.verbose) {
    for (final d in dropped) {
      print('   overlay-excluded dependency: $d');
    }
    for (final e in extras) {
      print('   overlay-added dependency: $e');
    }
  }
  return overrides.copyWith(extraDeps: [...kept, ...extras]);
}

/// Whether a Maven [coordinate] matches any [excludes] pattern: exact
/// coordinate, or `group:artifact:*` prefix exclusion.
bool matchesDependencyExclusion(String coordinate, List<String> excludes) {
  for (final pattern in excludes) {
    if (pattern == coordinate) return true;
    if (pattern.endsWith(':*') &&
        coordinate.startsWith(pattern.substring(0, pattern.length - 1))) {
      return true;
    }
  }
  return false;
}
