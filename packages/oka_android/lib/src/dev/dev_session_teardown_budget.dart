/// Shared wall-clock budget for one [DevSession] teardown phase only.
library;

import 'dart:async';

/// Injectable monotonic clock (tests prove budget is not created during long sessions).
typedef TeardownBudgetStopwatch = Stopwatch Function();

/// In-session teardown wall time (leaves margin under 45s cooperative stop).
///
/// Attach kill backstop (+2s) and CLI control-close / file IO sit outside this.
const kDevSessionTeardownBudgetTotal = Duration(seconds: 36);

/// One budget created when quit/detach/daemon teardown begins — not at attach.
final class DevSessionTeardownBudget {
  DevSessionTeardownBudget({
    this.total = kDevSessionTeardownBudgetTotal,
    Stopwatch? stopwatch,
  }) : _stopwatch = stopwatch ?? (Stopwatch()..start());

  final Duration total;
  final Stopwatch _stopwatch;

  bool get exhausted => _stopwatch.elapsed >= total;

  Duration get remaining {
    final left = total - _stopwatch.elapsed;
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
