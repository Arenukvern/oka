/// The resource budget of one verify run (ADR-0048).
///
/// Every external process the lane starts is bounded: a deadline, an output
/// cap and a worker count. A budget that is exceeded is reported, never
/// silently absorbed — a killed compile is a failure with a receipt, not a
/// missing dill.
library;

import 'dart:io';

/// The bounds of one verify run.
final class VerifyBudget {
  const VerifyBudget({
    this.compileTimeout = const Duration(minutes: 10),
    this.runTimeout = const Duration(minutes: 10),
    this.workers = 4,
    this.maxCapturedBytes = 1024 * 1024,
    this.maxEchoBytes = 4 * 1024 * 1024,
    this.gitTimeout = const Duration(seconds: 30),
  });

  /// The budget the CLI uses: workers scale with the host, the rest is the
  /// documented default.
  factory VerifyBudget.standard() =>
      VerifyBudget(workers: (Platform.numberOfProcessors - 2).clamp(2, 8));

  /// Deadline for one suite compile.
  final Duration compileTimeout;

  /// Deadline for the whole suite run.
  final Duration runTimeout;

  /// How many suite compiles may run in parallel.
  final int workers;

  /// How many bytes of compiler output are captured per stream.
  final int maxCapturedBytes;

  /// How many bytes of runner output are echoed to the console.
  final int maxEchoBytes;

  /// Deadline for the short git queries (revision, changed files).
  final Duration gitTimeout;

  @override
  String toString() =>
      'VerifyBudget(workers: $workers, '
      'compile: ${compileTimeout.inSeconds}s, run: ${runTimeout.inSeconds}s)';
}
