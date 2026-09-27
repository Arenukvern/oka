/// The composition: an immutable component graph, validated and explained
/// before any side effect (ADR-0026 decision 3).
library;

import 'component.dart';
import 'lifecycle.dart';
import 'readiness.dart';

/// One validation finding, named and actionable.
final class CompositionIssue {
  const CompositionIssue({
    required this.code,
    required this.message,
    this.componentId,
  });

  /// Stable machine-readable code, e.g. `cyclicDependency`.
  final String code;

  /// The component the issue is about, when attributable.
  final String? componentId;
  final String message;

  @override
  String toString() =>
      '$code${componentId == null ? '' : ' ($componentId)'}: $message';
}

/// The result of [Composition.validate]: a plan is inspectable and
/// explainable with zero side effects.
final class CompositionReport {
  const CompositionReport(this.issues);

  final List<CompositionIssue> issues;

  bool get ok => issues.isEmpty;

  /// Deterministic rendering for `oka explain`-style surfaces.
  String render() => issues.isEmpty
      ? 'composition valid'
      : issues.map((final issue) => issue.toString()).join('\n');
}

/// An immutable graph of named components plus the defaults the runner and
/// providers need (budgets, evidence policy).
final class Composition {
  const Composition({
    required this.components,
    this.readinessBudget = const Duration(seconds: 30),
    this.evidence,
  });

  final List<Component> components;

  /// Default readiness budget for conditions that do not override it.
  final Duration readinessBudget;

  /// Evidence sink; runners may supply their own, falling back to this.
  final Object? evidence;

  /// Pure validation of the graph: ids, dependencies, cycles, output
  /// promises, provider capabilities, lifecycle scope inversion, and
  /// readiness shape. Performs **no side effects** — providers are not
  /// contacted.
  CompositionReport validate() {
    final issues = <CompositionIssue>[];
    final byId = <String, Component>{};
    for (final component in components) {
      if (component.id.isEmpty) {
        issues.add(const CompositionIssue(
          code: 'invalidId',
          message: 'component id must be non-empty',
        ));
        continue;
      }
      if (byId.containsKey(component.id)) {
        issues.add(CompositionIssue(
          code: 'duplicateComponentId',
          componentId: component.id,
          message: 'duplicate component id',
        ));
        continue;
      }
      byId[component.id] = component;
    }

    for (final component in byId.values) {
      for (final dep in component.dependsOn) {
        if (!byId.containsKey(dep)) {
          issues.add(CompositionIssue(
            code: 'unknownDependency',
            componentId: component.id,
            message: 'depends on "$dep", which is not in the composition',
          ));
        }
      }

      // Readiness shape.
      final readiness = component.readiness;
      if (readiness != null) {
        if (!component.provider.capabilities.readinessProbe) {
          issues.add(CompositionIssue(
            code: 'capabilityReadiness',
            componentId: component.id,
            message:
                'declares readiness (${readiness.describe()}) but provider '
                '${component.provider.runtimeType} does not declare the '
                'readinessProbe capability; swap the provider or drop the '
                'readiness',
          ));
        }
        issues.addAll(_readinessIssues(component.id, readiness));
      }

      // Capability requirements.
      if (component.lifecycle.identity == IdentityRequirement.durable &&
          !component.provider.capabilities.durableIdentity) {
        issues.add(CompositionIssue(
          code: 'capabilityIdentity',
          componentId: component.id,
          message:
              'requires durable identity but provider '
              '${component.provider.runtimeType} does not declare the '
              'durableIdentity capability',
        ));
      }

      // Scope inversion (ADR-0025's retention table): a longer-lived
      // component must not depend on a shorter-lived one — the dependency
      // would die before its dependent.
      for (final dep in component.dependsOn) {
        final depComponent = byId[dep];
        if (depComponent == null) continue;
        if (_scopeRank(component.lifecycle.scope) >
            _scopeRank(depComponent.lifecycle.scope)) {
          issues.add(CompositionIssue(
            code: 'scopeInversion',
            componentId: component.id,
            message:
                '${component.lifecycle.scope.name} component depends on '
                '${depComponent.lifecycle.scope.name} "$dep"; the dependency '
                'outlives its dependent',
          ));
        }
      }
    }

    // Output promises: every `requires` must be produced transitively by
    // dependencies (direct or transitive closure).
    for (final component in byId.values) {
      if (component.requires.isEmpty) continue;
      final provided = <String>{};
      final stack = List.of(component.dependsOn);
      final seen = <String>{component.id};
      while (stack.isNotEmpty) {
        final id = stack.removeLast();
        if (!seen.add(id)) continue;
        final dep = byId[id];
        if (dep == null) continue;
        provided.addAll(dep.provides.map((final ref) => ref.id));
        stack.addAll(dep.dependsOn);
      }
      for (final ref in component.requires) {
        if (!provided.contains(ref.id)) {
          issues.add(CompositionIssue(
            code: 'unmetRequirement',
            componentId: component.id,
            message:
                'requires output "${ref.id}", which no (transitive) '
                'dependency provides',
          ));
        }
      }
    }

    // Cycles: DFS with a coloring pass (only when ids resolved cleanly).
    if (byId.length == components.length) {
      final state = <String, int>{}; // 1 = open, 2 = done
      void visit(final String id, final List<String> stack) {
        final current = state[id];
        if (current == 2) return;
        if (current == 1) {
          final from = stack.indexOf(id);
          final cycle = [...stack.sublist(from < 0 ? 0 : from), id];
          issues.add(CompositionIssue(
            code: 'cyclicDependency',
            componentId: id,
            message: 'dependency cycle: ${cycle.join(' -> ')}',
          ));
          return;
        }
        state[id] = 1;
        final next = stack..add(id);
        for (final dep in byId[id]!.dependsOn) {
          if (byId.containsKey(dep)) visit(dep, next);
        }
        state[id] = 2;
      }

      for (final id in byId.keys) {
        visit(id, <String>[]);
      }
    }

    issues.sort((final a, final b) {
      final byComponent = (a.componentId ?? '').compareTo(b.componentId ?? '');
      return byComponent != 0 ? byComponent : a.code.compareTo(b.code);
    });
    return CompositionReport(issues);
  }

  /// Deterministic plan text: components in declaration order with
  /// dependencies, readiness (with effective budget), and output promises.
  /// No side effects — providers are never contacted.
  String explain() {
    final report = validate();
    final buffer = StringBuffer()
      ..writeln(
        'Composition (${components.length} components; readiness budget '
        '${readinessBudget.inMilliseconds}ms) — ${report.render()}',
      );
    for (final component in components) {
      buffer
        ..writeln('- ${component.id} [${component.provider.runtimeType}]')
        ..writeln(
          '    scope: ${component.lifecycle.scope.name}, '
          'crash: ${component.lifecycle.onCrash.name}, '
          'identity: ${component.lifecycle.identity.name}',
        );
      if (component.dependsOn.isNotEmpty) {
        buffer.writeln('    dependsOn: ${component.dependsOn.join(', ')}');
      }
      if (component.readiness case final readiness?) {
        final budget = readiness.budget ?? readinessBudget;
        buffer.writeln(
          '    readyWhen: ${readiness.describe()} (budget '
          '${budget.inMilliseconds}ms)',
        );
      }
      if (component.requires.isNotEmpty) {
        final ids = component.requires.map((final r) => r.id).join(', ');
        buffer.writeln('    requires: $ids');
      }
      if (component.provides.isNotEmpty) {
        final ids = component.provides.map((final r) => r.id).join(', ');
        buffer.writeln('    provides: $ids');
      }
    }
    return buffer.toString().trimRight();
  }

  /// Rebuilds the graph. Variants are new values assembled from named
  /// parts — never string-keyed plan surgery.
  Composition copyWith({
    final List<Component>? components,
    final Duration? readinessBudget,
    final Object? evidence,
  }) =>
      Composition(
        components: components ?? this.components,
        readinessBudget: readinessBudget ?? this.readinessBudget,
        evidence: evidence ?? this.evidence,
      );
}

int _scopeRank(final ResourceScope scope) => switch (scope) {
      ResourceScope.ephemeral => 0,
      ResourceScope.session => 1,
      ResourceScope.persistent => 2,
    };

List<CompositionIssue> _readinessIssues(
  final String componentId,
  final Readiness readiness,
) {
  final issues = <CompositionIssue>[];
  switch (readiness) {
    case FilePresent(:final path):
      if (path.trim().isEmpty) {
        issues.add(CompositionIssue(
          code: 'invalidReadiness',
          componentId: componentId,
          message: 'FilePresent path must be non-empty',
        ));
      }
    case ReadinessAll(:final conditions):
      if (conditions.isEmpty) {
        issues.add(CompositionIssue(
          code: 'invalidReadiness',
          componentId: componentId,
          message: 'ReadinessAll requires at least one condition; '
              'use a null readiness instead',
        ));
      }
      for (final inner in conditions) {
        if (inner is ReadinessAll) {
          issues.add(CompositionIssue(
            code: 'invalidReadiness',
            componentId: componentId,
            message: 'nested ReadinessAll; flatten the conjunction',
          ));
        }
      }
    case HandshakeLine() || LogPattern() || TcpConnect():
      break;
  }
  return issues;
}
