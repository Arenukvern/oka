/// Composable patch targets. A target is "a running program that can accept
/// a patch over a wire" — nothing more. The session composes any number of
/// them; adding a platform means adding a target, not changing the session.
library;

import 'spec.dart';

/// What the target did with the delta.
class ApplyOutcome {
  const ApplyOutcome({
    required this.ok,
    required this.mode,
    this.error,
    this.wire = const {},
  });

  final bool ok;

  /// Which wire method carried the delta, e.g. `reloadKernel`,
  /// `reloadSources(rootLibUri)`, `dwds reloadSources`,
  /// `staged-next-launch`.
  final String mode;
  final String? error;

  /// Raw wire facts worth keeping in a receipt (report, counts).
  final Map<String, Object?> wire;
}

abstract class LivePatchTarget {
  String get id;
  String get kind;

  /// Connects to the running program. Idempotent per run.
  Future<void> connect();

  /// Applies the compiled unit delta. For web targets the platform
  /// toolchain recompiles from source before this is called; the delta is
  /// then advisory (bytes are reported, not consumed).
  Future<ApplyOutcome> apply({
    required String unit,
    required String deltaPath,
    required int deltaBytes,
  });

  /// Evaluates a probe expression in the running program; returns its
  /// value as a string.
  Future<String> evaluate(ProbeSpec probe);

  Future<void> close();
}
