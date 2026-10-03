/// Kernel adapter for the unit partitioner (`package:oka_dart_kernel`
/// `lib/src/unit_graph.dart`): builds the import graph from a [Component],
/// runs the dependency-ordered partition, and applies the plan —
/// DeferredFlag on every cross-boundary import, synthetic deferred imports
/// on the entry, `await LoadLibrary` guards at the start of `main` in
/// dependency order.
///
/// ADR-0032 G2.5. Lives in tool/ because package:kernel resolves only in the
/// checkout-provisioned gate environment (see tool/gate_g1b_g2.sh).
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:oka_dart_kernel/src/unit_graph.dart';

/// Applied partition result, for gates and reports.
class DeferredizeResult {
  final UnitPartitionPlan plan;

  /// uri -> unit pattern for every library that left the root unit.
  final Map<Uri, String> libraryUnits;

  DeferredizeResult({required this.plan, required this.libraryUnits});

  bool isUnitMember(Uri uri) => libraryUnits.containsKey(uri);

  /// Re-applies the deferred flags after mid-pipeline transformations:
  /// passes between the CFE and the loading-unit computation (notably
  /// `dart:mixin_deduplication`) synthesize libraries with fresh
  /// non-deferred edges into unit members, which would otherwise drag the
  /// members back into the root loading unit.
  int reapplyDeferredFlags(Component component) {
    var flagged = 0;
    for (final lib in component.libraries) {
      final fromPattern = libraryUnits[lib.importUri];
      for (final dep in lib.dependencies) {
        if (dep.isDeferred) continue;
        final toPattern = libraryUnits[dep.targetLibrary.importUri];
        if (toPattern == null || toPattern == fromPattern) continue;
        dep.flags |= LibraryDependency.DeferredFlag;
        flagged++;
      }
    }
    if (flagged > 0) {
      stdout.writeln('deferredize: re-flagged $flagged edges introduced by '
          'mid-pipeline transformations');
    }
    return flagged;
  }
}

/// Applies unit partitioning to [component] for the declared [patterns].
///
/// With empty [patterns] this is a no-op (the G1b shape). [insertGuards]
/// controls the `await LoadLibrary` guards in main: AOT part units are
/// mapped by the loader, so flags-only partitioning runs without them —
/// required for sync mains (`void main() { runApp(...) }`), where an
/// inserted await cannot be lowered.
DeferredizeResult? deferredizeUnits(
  Component component,
  List<String> patterns, {
  bool insertGuards = true,
}) {
  if (patterns.isEmpty) return null;
  final entry = component.mainMethod?.enclosingLibrary;
  if (entry == null) throw StateError('no main library');

  final graph = _graphFrom(component, entry);
  final plan = graph.partition(patterns);

  // 1. Flag every cross-boundary dependency edge deferred — imports AND
  //    exports (barrel exports are the seam in real apps; the VM's loading
  //    unit computation reads `isDeferred` off either kind).
  final byUri = {
    for (final lib in component.libraries) lib.importUri: lib,
  };
  final edgeKeys = plan.deferredEdges.toSet();
  var flagged = 0;
  for (final lib in component.libraries) {
    for (final dep in lib.dependencies) {
      if (dep.isDeferred) continue;
      final target = dep.targetLibrary.importUri;
      if (edgeKeys.contains(UriEdge(lib.importUri, target))) {
        dep.flags |= LibraryDependency.DeferredFlag;
        flagged++;
      }
    }
  }

  // 2. Synthetic deferred import on the entry per unit (main may reach the
  //    unit only transitively — through bootstrap/router in a real app).
  //    REQUIRED: the AOT backend keys loading units off deferred imports
  //    reachable from the entry; deferred export flags alone don't split.
  //    This is a kernel-level import — no source changes.
  final main = component.mainMethod!;
  final entryDeps = <LibraryDependency>[];
  for (var i = 0; i < plan.units.length; i++) {
    final unit = plan.units[i];
    final seed = byUri[unit.guardSeed];
    if (seed == null) {
      throw StateError('unit seed `${unit.guardSeed}` not in component');
    }
    final dep = LibraryDependency.deferredImport(seed, 'oka_unit$i');
    entry.addDependency(dep);
    entryDeps.add(dep);
  }

  // 3. Optional `await LoadLibrary` guards at the start of main,
  //    dependencies first. AOT part units are mapped by the loader, so the
  //    guards are not needed for the AOT lane — and a sync main
  //    (`void main() { runApp(...) }`) cannot take an inserted await:
  //    async bodies are lowered by the CFE, and a post-CFE marker flip
  //    aborts the AOT loader at teardown.
  final body = main.function.body;
  if (insertGuards) {
    // The guards contain `await`; async bodies are lowered by the CFE, so a
    // post-CFE marker flip on a sync main produces an unlowered async body
    // that aborts the AOT loader at teardown. Refuse with a clear error —
    // the app must declare `Future<void> main() async` (the standard Dart
    // deferred-loading shape).
    if (main.function.asyncMarker != AsyncMarker.Async) {
      throw StateError(
        'unit load guards need an async main (`Future<void> main() async`); '
        'found sync main in ${entry.importUri}. Re-run with --no-guards '
        'only for entries that never touch unit code before an explicit '
        'load, or make main async.',
      );
    }
    final guards = <Statement>[
      for (final dep in entryDeps)
        ExpressionStatement(AwaitExpression(LoadLibrary(dep))),
    ];
    if (body is Block) {
      for (var i = 0; i < guards.length; i++) {
        body.statements.insert(i, guards[i]);
      }
    } else if (body != null) {
      final block = Block([...guards, body]);
      main.function.body = block..parent = main.function;
    } else {
      throw StateError('main has no body');
    }
    stdout.writeln('deferredize: ${guards.length} load guards in main');
  } else {
    stdout.writeln('deferredize: guards skipped (--no-guards); synthetic '
        'entry imports still added');
  }

  stdout.writeln(
    'deferredize: ${plan.units.length} units, ${flagged} cross edges '
    'deferred, ${plan.sharedLibraries.length} libs shared with root',
  );
  for (final edge in plan.deferredEdges) {
    stdout.writeln('deferredize: edge $edge');
  }
  for (final unit in plan.units) {
    stdout.writeln(
      'deferredize: unit `${unit.pattern}` = ${unit.members.length} libs, '
      'guard=${unit.guardSeed}',
    );
    for (final member in unit.members) {
      stdout.writeln('deferredize:   ${member}');
    }
  }

  return DeferredizeResult(
    plan: plan,
    libraryUnits: {
      for (final unit in plan.units)
        for (final member in unit.members) member: unit.pattern,
    },
  );
}

UnitGraph _graphFrom(Component component, Library entry) {
  // Every dependency kind matters to the VM's loading-unit dominator tree —
  // barrels export their modules, and an export edge keeps the target in the
  // exporter's unit unless it is flagged deferred exactly like an import.
  final edges = <Uri, List<Uri>>{};
  for (final lib in component.libraries) {
    final targets = <Uri>[];
    for (final dep in lib.dependencies) {
      final target = dep.targetLibrary;
      if (target.importUri.scheme == 'dart') continue;
      if (target.importUri == lib.importUri) continue;
      targets.add(target.importUri);
    }
    edges[lib.importUri] = targets;
  }
  return UnitGraph(entry: entry.importUri, imports: edges);
}
