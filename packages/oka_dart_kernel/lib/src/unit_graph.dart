/// Unit partitioning over an import graph (ADR-0032 G2.5).
///
/// Pure graph logic, kernel-free: the kernel adapter (`tool/`) feeds
/// import-uri patterns and the component's import edges in, then applies the
/// returned plan to the kernel AST. Splitting the logic out keeps the
/// partitioning algorithm under ordinary `dart test` while `package:kernel`
/// stays confined to the checkout-provisioned gate environment.
library;

import 'package:meta/meta.dart';

/// Matches a library import-uri against a declared unit pattern.
///
/// - `package:foo/` — prefix match (a whole package, or a package folder
///   like `package:foo/features/`);
/// - `units/tiny.dart` — path suffix match (a file inside the entry's own
///   tree).
bool uriMatchesPattern(Uri uri, String pattern) {
  final s = uri.toString();
  if (pattern.endsWith('/')) return s.startsWith(pattern);
  return s == pattern || s.endsWith('/$pattern') || s.endsWith(pattern);
}

bool _isSdk(Uri uri) => uri.scheme == 'dart';

/// A directed import edge between two libraries, identified by import-uri.
@immutable
class UriEdge {
  const UriEdge(this.from, this.to);

  final Uri from;
  final Uri to;

  @override
  bool operator ==(Object other) =>
      other is UriEdge && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => '$from -> $to';
}

/// One partitioned unit after [UnitGraph.partition].
class UnitPartition {
  const UnitPartition({
    required this.pattern,
    required this.members,
    required this.guardSeed,
  });

  /// The declared pattern this unit came from.
  final String pattern;

  /// Final member libraries, in a stable order. Libraries the entry reaches
  /// without crossing a deferred edge stay in the root loading unit instead.
  final List<Uri> members;

  /// Library the synthesized entry import points at (a seed the app actually
  /// imports, when possible, so the guard covers the app's real seam).
  final Uri guardSeed;

  @override
  String toString() =>
      'UnitPartition($pattern: ${members.length} libs, guard=$guardSeed)';
}

/// The partition a graph produces for a set of declared unit patterns.
class UnitPartitionPlan {
  const UnitPartitionPlan({
    required this.units,
    required this.deferredEdges,
    required this.sharedLibraries,
  });

  /// Units in load order: every unit appears after all units it depends on.
  final List<UnitPartition> units;

  /// Import edges that must be marked deferred: every edge entering a unit
  /// from outside it (from the root — entry side — or from another unit).
  final List<UriEdge> deferredEdges;

  /// Raw-closure libraries that ended up in the root unit because the entry
  /// reaches them without crossing a deferred edge.
  final List<Uri> sharedLibraries;
}

/// Thrown when the declared units cannot form a valid loading-unit DAG.
class UnitPartitionException implements Exception {
  UnitPartitionException(this.message);

  final String message;

  @override
  String toString() => 'UnitPartitionException: $message';
}

/// The library import graph of a compiled component, as seen by the
/// partitioner.
class UnitGraph {
  UnitGraph({required this.entry, required Map<Uri, List<Uri>> imports})
      : imports = Map.of(imports);

  /// The entry library's import-uri.
  final Uri entry;

  /// `library -> libraries it imports` (imports only; exports carry no
  /// code dependency for loading-unit purposes).
  final Map<Uri, List<Uri>> imports;

  /// Computes the dependency-ordered partition for [patterns].
  ///
  /// Algorithm:
  /// 1. seeds(pattern) — libraries matching the pattern;
  /// 2. raw closure per unit — transitively imported libraries, stopping at
  ///    SDK libraries, the entry, and other units' seeds;
  /// 3. fixpoint over the deferred edge set D: start with every edge entering
  ///    a unit's seed set from outside it, then recompute root reachability
  ///    (paths crossing no edge of D) and unit membership (raw closure minus
  ///    root-reachable) until both stabilize. A direct root import of a
  ///    closure library therefore keeps that library in the root unit;
  /// 4. the final cross-boundary edges are exactly D; edges between two
  ///    units yield the inter-unit dependency DAG;
  /// 5. topological order (dependencies first), cycle ->
  ///    [UnitPartitionException].
  UnitPartitionPlan partition(List<String> patterns) {
    if (patterns.isEmpty) {
      throw UnitPartitionException('no unit patterns declared');
    }

    final seedsPerPattern = <String, Set<Uri>>{};
    for (final pattern in patterns) {
      final seeds = imports.keys
          .where((uri) => uri != entry && uriMatchesPattern(uri, pattern))
          .toSet();
      if (seeds.isEmpty) {
        throw UnitPartitionException('pattern `$pattern` matched no libraries');
      }
      seedsPerPattern[pattern] = seeds;
    }

    final allSeeds = seedsPerPattern.values.expand((s) => s).toSet();

    // 2. Raw closures. A unit never absorbs another unit's seed — that edge
    // becomes an inter-unit dependency.
    final rawClosure = <String, Set<Uri>>{};
    for (final entry_ in seedsPerPattern.entries) {
      final seen = <Uri>{...entry_.value};
      final queue = <Uri>[...entry_.value];
      while (queue.isNotEmpty) {
        final lib = queue.removeLast();
        for (final next in imports[lib] ?? const <Uri>[]) {
          if (_isSdk(next) || next == entry || allSeeds.contains(next)) {
            continue;
          }
          if (seen.add(next)) queue.add(next);
        }
      }
      rawClosure[entry_.key] = seen;
    }

    // 3. Fixpoint over the deferred edge set. Initial edges: everything
    // entering a seed set, except seed->seed edges inside the same unit.
    // Real apps have circular imports (screens import the router, the router
    // imports the screens), so the entering edge may come from inside the
    // unit's own raw closure — deferring it is still correct: the synthetic
    // entry import anchors the seam.
    final deferred = <UriEdge>{
      for (final e in _allEdges())
        if (_entersSeed(e, seedsPerPattern)) e,
    };

    var members = <String, Set<Uri>>{};
    while (true) {
      final rootReach = _reachableSkipping(deferred);
      final next = <String, Set<Uri>>{
        for (final entry_ in rawClosure.entries)
          entry_.key: entry_.value.difference(rootReach),
      };
      final stable = members.isNotEmpty && _sameMembers(next, members);
      members = next;
      if (stable) break;
      deferred.addAll([
        for (final e in _allEdges())
          if (memberToPatternOrNull(e.to, members) != null &&
              memberToPatternOrNull(e.from, members) !=
                  memberToPatternOrNull(e.to, members))
            e,
      ]);
    }

    // 4. Shared candidates that ended up root, and the final cross edges.
    final shared = <Uri>{};
    for (final entry_ in rawClosure.entries) {
      shared.addAll(
        entry_.value.difference(members[entry_.key] ?? const <Uri>{}),
      );
    }
    final deferredEdges = deferred
        .where((e) => memberToPatternOrNull(e.to, members) != null)
        .toList()
      ..sort((a, b) => a.toString().compareTo(b.toString()));

    final unitDeps = <String, Set<String>>{};
    for (final edge in deferredEdges) {
      final fromPattern = memberToPatternOrNull(edge.from, members);
      final toPattern = memberToPatternOrNull(edge.to, members);
      if (fromPattern != null && fromPattern != toPattern) {
        unitDeps.putIfAbsent(fromPattern, () => <String>{}).add(toPattern!);
      }
    }

    // 5. Topological order (dependencies first), deterministic by pattern.
    final orderedUnits = <UnitPartition>[];
    final remaining = {
      for (final p in patterns) p: unitDeps[p]?.toSet() ?? <String>{},
    };
    while (remaining.isNotEmpty) {
      final ready = remaining.entries
          .where((e) => e.value.every((d) => !remaining.containsKey(d)))
          .map((e) => e.key)
          .toList()
        ..sort();
      if (ready.isEmpty) {
        throw UnitPartitionException(
          'unit dependency cycle: ${remaining.keys.toList()..sort()}',
        );
      }
      for (final pattern in ready) {
        final membersList = members[pattern]!.toList()
          ..sort((a, b) => a.toString().compareTo(b.toString()));
        orderedUnits.add(
          UnitPartition(
            pattern: pattern,
            members: membersList,
            guardSeed: _pickGuardSeed(
              seeds: seedsPerPattern[pattern]!,
              members: membersList,
            ),
          ),
        );
        remaining.remove(pattern);
      }
    }

    return UnitPartitionPlan(
      units: orderedUnits,
      deferredEdges: deferredEdges,
      sharedLibraries: shared.toList()
        ..sort((a, b) => a.toString().compareTo(b.toString())),
    );
  }

  Iterable<UriEdge> _allEdges() sync* {
    for (final entry_ in imports.entries) {
      for (final to in entry_.value) {
        yield UriEdge(entry_.key, to);
      }
    }
  }

  /// True when the edge enters some unit's seed set from a non-seed of that
  /// same unit (seed->seed edges stay non-deferred).
  bool _entersSeed(UriEdge edge, Map<String, Set<Uri>> seedsPerPattern) {
    for (final seeds in seedsPerPattern.values) {
      if (!seeds.contains(edge.to)) continue;
      if (!seeds.contains(edge.from)) return true;
    }
    return false;
  }

  /// Libraries reachable from the entry without crossing [deferred] edges.
  Set<Uri> _reachableSkipping(Set<UriEdge> deferred) {
    final seen = <Uri>{entry};
    final queue = <Uri>[entry];
    while (queue.isNotEmpty) {
      final lib = queue.removeLast();
      for (final next in imports[lib] ?? const <Uri>[]) {
        if (deferred.contains(UriEdge(lib, next))) continue;
        if (seen.add(next)) queue.add(next);
      }
    }
    return seen;
  }

  /// Prefer a seed the entry actually imports (the app's real seam), then
  /// the lexicographically smallest member for determinism.
  Uri _pickGuardSeed({required Set<Uri> seeds, required List<Uri> members}) {
    final directSeeds =
        (imports[entry] ?? const <Uri>[]).where(seeds.contains).toSet();
    final candidates = (directSeeds.isNotEmpty ? directSeeds : seeds.toSet())
        .where(members.contains)
        .toList()
      ..sort((a, b) => a.toString().compareTo(b.toString()));
    if (candidates.isNotEmpty) return candidates.first;
    return members.first;
  }
}

String? memberToPatternOrNull(Uri? uri, Map<String, Set<Uri>> members) {
  if (uri == null) return null;
  for (final entry_ in members.entries) {
    if (entry_.value.contains(uri)) return entry_.key;
  }
  return null;
}

bool _sameMembers(Map<String, Set<Uri>> a, Map<String, Set<Uri>> b) {
  if (a.length != b.length) return false;
  for (final entry_ in a.entries) {
    if (entry_.value.difference(b[entry_.key] ?? {}).isNotEmpty) return false;
  }
  return true;
}
