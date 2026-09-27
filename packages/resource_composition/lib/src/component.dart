/// The component value: one node of the composition graph.
///
/// Components are small immutable values assembled by constructor
/// injection — the house style of ADR-0002 steps and ADR-0025 workflows.
/// Ids exist for `explain`, events, and CLI surfaces; variants rebuild the
/// graph from named values, they never mutate by string key.
library;

import 'lifecycle.dart';
import 'outputs.dart';
import 'provider.dart';
import 'readiness.dart';

/// One declared resource in a [Composition].
final class Component {
  const Component({
    required this.id,
    required this.provider,
    this.dependsOn = const <String>[],
    this.requires = const <OutputRef<Object?>>[],
    this.provides = const <OutputRef<Object?>>[],
    this.readiness,
    this.lifecycle = const Lifecycle(),
    this.diagnostics = const Diagnostics(),
  });

  /// Stable, unique within a composition.
  final String id;

  /// The provider implementing this component's mechanics.
  final ResourceProvider provider;

  /// Ids of components this one depends on; they start first, and an
  /// unready dependency never satisfies the edge.
  final List<String> dependsOn;

  /// Output promises this component consumes at start time; every ref must
  /// be produced (transitively) by a dependency.
  final List<OutputRef<Object?>> requires;

  /// Output promises this component resolves when it becomes ready.
  final List<OutputRef<Object?>> provides;

  /// The declared readiness condition, when the component has one.
  final Readiness? readiness;

  final Lifecycle lifecycle;
  final Diagnostics diagnostics;

  Component copyWith({
    final ResourceProvider? provider,
    final List<String>? dependsOn,
    final List<OutputRef<Object?>>? requires,
    final List<OutputRef<Object?>>? provides,
    final Readiness? readiness,
    final Lifecycle? lifecycle,
    final Diagnostics? diagnostics,
  }) =>
      Component(
        id: id,
        provider: provider ?? this.provider,
        dependsOn: dependsOn ?? this.dependsOn,
        requires: requires ?? this.requires,
        provides: provides ?? this.provides,
        readiness: readiness ?? this.readiness,
        lifecycle: lifecycle ?? this.lifecycle,
        diagnostics: diagnostics ?? this.diagnostics,
      );
}
