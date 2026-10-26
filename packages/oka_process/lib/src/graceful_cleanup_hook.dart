import 'package:meta/meta.dart';

/// Optional hook invoked before SIGTERM; success is never settlement evidence.
@immutable
final class GracefulCleanupHook {
  const GracefulCleanupHook({
    required this.run,
    this.timeout = const Duration(seconds: 1),
  });

  /// Runs cleanup; may be async in implementations.
  final Future<void> Function() run;

  /// Bounded inside the session [ObservationBudget].
  final Duration timeout;
}
