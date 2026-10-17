import 'dart:async';

/// Identifies this budget's expiry, distinct from a mutating adapter timeout.
final class ProcessObservationTimeout extends TimeoutException {
  ProcessObservationTimeout(Duration budget)
    : super('process observation budget exhausted; survivors unknown', budget);
}

/// Internal budget for serialized, read-only platform observations.
/// Timing out the await does not cancel the injected read or its resources.
/// Never wrap a mutating adapter with this class.
final class ProcessObservationBudget {
  ProcessObservationBudget(this.limit) {
    if (limit <= Duration.zero) {
      throw ArgumentError.value(limit, 'observationBudget', 'must be positive');
    }
  }
  final Duration limit;
  final _spent = Stopwatch();

  Future<T> read<T>(Future<T> Function() observe) async {
    final remaining = limit - _spent.elapsed;
    if (remaining <= Duration.zero) {
      throw ProcessObservationTimeout(limit);
    }
    _spent.start();
    try {
      final value = await observe().timeout(
        remaining,
        onTimeout: () => throw ProcessObservationTimeout(limit),
      );
      if (_spent.elapsed > limit) {
        throw ProcessObservationTimeout(limit);
      }
      return value;
    } finally {
      _spent.stop();
    }
  }
}
