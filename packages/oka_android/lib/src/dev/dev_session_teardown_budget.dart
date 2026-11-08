/// Shared wall-clock budget for one [DevSession] quit teardown (caller ~45s).
library;

import 'dart:async';

/// One overall budget (default 44s) shared by app.stop, adb, and attach exit.
final class DevSessionTeardownBudget {
  DevSessionTeardownBudget({Duration total = const Duration(seconds: 44)})
    : _deadline = DateTime.now().add(total);

  final DateTime _deadline;

  bool get exhausted => DateTime.now().isAfter(_deadline);

  Duration get remaining {
    final left = _deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Caps [operation] at [cap] and at [remaining]; throws on overall expiry.
  Future<T> run<T>(
    Future<T> Function() operation, {
    required Duration cap,
  }) {
    if (exhausted) {
      throw DevSessionTeardownBudgetExhausted();
    }
    final slice = remaining < cap ? remaining : cap;
    if (slice <= Duration.zero) {
      throw DevSessionTeardownBudgetExhausted();
    }
    return operation().timeout(slice);
  }
}

/// Thrown when the shared teardown budget is exhausted.
final class DevSessionTeardownBudgetExhausted implements Exception {}
