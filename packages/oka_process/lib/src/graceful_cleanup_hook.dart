import 'package:meta/meta.dart';

/// Optional hook run on leader `term` before group SIGTERM+SIGCONT (p1).
/// Success is never settlement evidence.
@immutable
final class GracefulCleanupHook {
  const GracefulCleanupHook({
    required this.run,
    this.timeout = const Duration(seconds: 2),
  });

  /// Runs cleanup; may be async in implementations.
  final Future<void> Function() run;

  /// Bounded inside the session [ObservationBudget].
  final Duration timeout;
}
