/// Dependency-plan dry-run (ADR-0008): compose the plugin dependency plan
/// from declared inputs (gradle-parsed, conditionally deduplicated) and
/// resolve it through `DependencyCache` — the same resolver service the
/// build's `DependencyResolveStep`/`PluginPackagingStep` use, composed
/// read-only.
///
/// Policy (ADR-0007/0008): cache-only by default (`allowNetwork: false`) so
/// `oka explain --deps` stays fast and side-effect-free; `--network` opts in
/// to full resolution, where a hard failure makes the dry-run exit non-zero.
library;
import 'package:oka_core/oka_core.dart';

import 'build/dependency_cache.dart';
import 'build/plugin_discovery.dart';
import 'build/plugin_packager.dart';

/// One source of declared dependencies: a plugin, `pipeline.extra_deps`, or
/// the flutter-embedding AndroidX set.
class DependencyPlanEntry {

  const DependencyPlanEntry({
    required this.source,
    required this.rootCoords,
    this.extraRepos = const [],
  });
  final String source;
  final List<MavenCoordinate> rootCoords;
  final List<String> extraRepos;
}

/// One resolution finding.
class DependencyPlanFinding {

  const DependencyPlanFinding({
    required this.source,
    required this.message, required this.fatal, this.coordinate,
  });
  final String source;
  final MavenCoordinate? coordinate;
  final String message;

  /// True when the plan cannot proceed like a build would (resolution failed
  /// with network on, or a malformed declared coordinate).
  final bool fatal;

  @override
  String toString() =>
      '${fatal ? '❌' : '⚠️ '} ${coordinate?.toString() ?? source}: $message';
}

/// Composed + resolved dependency plan.
class DependencyPlanReport {

  const DependencyPlanReport({
    required this.entries,
    required this.resolved,
    required this.findings,
    required this.cacheOnly,
  });
  final List<DependencyPlanEntry> entries;
  final List<ResolvedJar> resolved;
  final List<DependencyPlanFinding> findings;

  /// True when resolution ran against the local cache only (no network):
  /// POM transitives are not expanded offline.
  final bool cacheOnly;

  bool get hasFatal => findings.any((final f) => f.fatal);

  int get rootCount =>
      entries.fold(0, (final sum, final e) => sum + e.rootCoords.length);

  /// Multi-line printable summary (without the section header).
  String summary() {
    final b = StringBuffer();
    b.writeln(
      '  sources: ${entries.map((final e) => '${e.source} (${e.rootCoords.length})').join(', ')}',
    );
    b.writeln(
      '  roots: $rootCount, resolved: ${resolved.length}'
      '${cacheOnly ? ' (cache-only — transitives not expanded)' : ''}',
    );
    if (findings.isEmpty) {
      b.writeln('  ✅ all declared dependencies resolve');
    }
    for (final f in findings) {
      b.writeln('  $f');
    }
    if (cacheOnly && findings.any((final f) => !f.fatal)) {
      b.writeln(
        '  ℹ️  cache-only run: re-run with `oka explain --deps --network` '
        'to fetch missing artifacts and expand transitives',
      );
    }
    return b.toString().trimRight();
  }
}

/// Compose the dependency plan from [plugins] + [extraDeps] and resolve it.
///
/// [packager] supplies the declared-deps collector (shared with the build
/// path so plan and packaging cannot disagree); [cache] performs resolution
/// with `allowNetwork` set by the caller (cache-only default, ADR-0008).
Future<DependencyPlanReport> buildDependencyPlan({
  required final List<DiscoveredPlugin> plugins,
  required final PluginPackager packager, required final DependencyCache cache, required final bool allowNetwork, final List<String> extraDeps = const [],
}) async {
  final entries = <DependencyPlanEntry>[];
  final collectionFindings = <DependencyPlanFinding>[];

  for (final plugin in plugins) {
    try {
      final hasKt = await packager.hasKotlinSources(plugin);
      final declared = await packager.collectDeclaredDeps(
        plugin,
        hasKotlinSources: hasKt,
      );
      if (declared.rootCoords.isEmpty && declared.extraRepos.isEmpty) continue;
      entries.add(
        DependencyPlanEntry(
          source: plugin.name,
          rootCoords: declared.rootCoords,
          extraRepos: declared.extraRepos,
        ),
      );
    } on Exception catch (e) {
      collectionFindings.add(
        DependencyPlanFinding(
          source: plugin.name,
          message: 'plan collection failed: $e',
          fatal: true,
        ),
      );
    }
  }

  // pipeline.extra_deps (oka.yaml fast-settings).
  final extraCoords = <MavenCoordinate>[];
  for (final dep in extraDeps) {
    final coord = MavenCoordinate.parse(dep);
    if (coord == null) {
      collectionFindings.add(
        DependencyPlanFinding(
          source: 'pipeline.extra_deps',
          message: 'malformed coordinate "$dep" (expected group:artifact:version)',
          fatal: true,
        ),
      );
      continue;
    }
    extraCoords.add(coord);
  }
  if (extraCoords.isNotEmpty) {
    entries.add(
      DependencyPlanEntry(source: 'pipeline.extra_deps', rootCoords: extraCoords),
    );
  }

  // Flutter embedding AndroidX set — resolved by every build
  // (DependencyResolveStep), so the plan must cover it too.
  final embedding = flutterEmbeddingAndroidXDeps();
  if (embedding.isNotEmpty) {
    entries.add(
      DependencyPlanEntry(source: 'flutter-embedding', rootCoords: embedding),
    );
  }

  // Resolve the union (per-source attribution for failures via lookup below).
  final allRoots = <MavenCoordinate>[
    for (final e in entries) ...e.rootCoords,
  ];
  final extraRepos = <String>{
    for (final e in entries) ...e.extraRepos,
  }.toList();

  String sourceFor(final MavenCoordinate c) {
    for (final e in entries) {
      if (e.rootCoords.any((final r) => r.cacheKey == c.cacheKey)) return e.source;
    }
    return 'plan';
  }

  final failures = <(MavenCoordinate, Object)>[];
  final resolved = allRoots.isEmpty
      ? const <ResolvedJar>[]
      : await cache.resolveWithTransitives(
          allRoots,
          extraRepos: extraRepos,
          onFailure: (final coord, final error) => failures.add((coord, error)),
        );

  final findings = [...collectionFindings];
  for (final (coord, error) in failures) {
    final offlineMiss = !allowNetwork &&
        error.toString().contains('network disabled');
    findings.add(
      DependencyPlanFinding(
        source: sourceFor(coord),
        coordinate: coord,
        message: offlineMiss
            ? 'not in local maven cache (offline mode)'
            : 'resolution failed: $error',
        fatal: !offlineMiss,
      ),
    );
  }

  return DependencyPlanReport(
    entries: entries,
    resolved: resolved,
    findings: findings,
    cacheOnly: !allowNetwork,
  );
}
