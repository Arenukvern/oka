/// Fail-closed spec validation (TypedSpec shape).
library;

/// Thrown when [validate] returns one or more violations.
final class SpecViolationException implements Exception {
  SpecViolationException(this.violations)
    : assert(violations.isNotEmpty, 'violations must not be empty');

  final List<String> violations;

  @override
  String toString() =>
      'SpecViolationException(${violations.length} violation(s)): '
      '${violations.join('; ')}';
}

/// Collects every violation; never throws from [validate].
mixin TypedSpec {
  List<String> validate();

  /// Throws [SpecViolationException] listing every violation when invalid.
  void ensureValid() {
    final problems = validate();
    if (problems.isNotEmpty) {
      throw SpecViolationException(problems);
    }
  }
}
