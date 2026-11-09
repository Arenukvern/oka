/// Shared wall-clock budget for one [DevSession] teardown phase only.
library;

import 'dart:async';

/// Injectable clock (tests prove budget is not created during long sessions).
typedef TeardownBudgetNow = DateTime Function();

/// In-session teardown wall time (leaves margin under 45s cooperative stop).
///
/// Attach kill backstop (+2s) and CLI control-close / file IO sit outside this.
const kDevSessionTeardownBudgetTotal = Duration(seconds: 36);

/// One budget created when quit/detach/daemon teardown begins — not at attach.
final class DevSessionTeardownBudget {
  DevSessionTeardownBudget({
    Duration total = kDevSessionTeardownBudgetTotal,
    TeardownBudgetNow? now,
  }) : _now = now ?? DateTime.now,
       _deadline = (now ?? DateTime.now)().add(total);

  final TeardownBudgetNow _now;
  final DateTime _deadline;

  bool get exhausted => _now().isAfter(_deadline);

  Duration get remaining {
    final left = _deadline.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

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

final class DevSessionTeardownBudgetExhausted implements Exception {}
