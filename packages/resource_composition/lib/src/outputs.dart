/// Typed output promises (ADR-0026 decision 4).
///
/// A producer component declares the outputs its readiness observation
/// parses into ([OutputRef]); dependents name them in `requires` and the
/// runtime injects resolved values at start time. Nothing but ids and types
/// crosses composition time — this is what makes ephemeral ports and
/// late-bound URIs composable without breaking validate-before-side-effects.
library;

/// A typed promise one component produces when it becomes ready.
///
/// Refs are values: declare them once as consts and share them between
/// producer and consumer.
///
/// ```dart
/// const collectorPort = OutputRef<int>('collector.port');
/// ```
final class OutputRef<T> {
  const OutputRef(this.id);

  /// Stable name; must be unique within a composition's declared outputs.
  final String id;

  @override
  String toString() => 'OutputRef<$T>($id)';
}

/// Output values a provider resolved while becoming ready, keyed by
/// [OutputRef.id], handed to dependents through [StartRequest.dependencies]
/// (see `provider.dart`).
final class ResolvedOutputs {
  /// Wraps already-resolved values; keys are [OutputRef.id] strings.
  const ResolvedOutputs([this._values = const <String, Object?>{}]);

  static const empty = ResolvedOutputs();

  final Map<String, Object?> _values;

  /// Whether [ref] was resolved. Composition-time `requires` validation
  /// guarantees producers; runtime checks catch provider bugs.
  bool contains(final OutputRef<Object?> ref) => _values.containsKey(ref.id);

  /// The typed value for [ref].
  ///
  /// Throws [StateError] with an actionable message when the output was not
  /// resolved or has the wrong runtime type — both are provider contract
  /// violations, never composition errors.
  T require<T>(final OutputRef<T> ref) {
    if (!_values.containsKey(ref.id)) {
      throw StateError(
        'Output "${ref.id}" was not resolved by its producer; the provider '
        'violated its declared provides.',
      );
    }
    final value = _values[ref.id];
    if (value is! T) {
      throw StateError(
        'Output "${ref.id}" is ${value.runtimeType}, expected $T; the '
        'provider violates its declared OutputRef type.',
      );
    }
    return value;
  }

  /// A view of this instance filtered to [ids]; used to hand a dependent
  /// exactly its declared requirements.
  ResolvedOutputs scopedTo(final Iterable<OutputRef<Object?>> refs) =>
      ResolvedOutputs({
        for (final ref in refs)
          if (_values.containsKey(ref.id)) ref.id: _values[ref.id],
      });
}
