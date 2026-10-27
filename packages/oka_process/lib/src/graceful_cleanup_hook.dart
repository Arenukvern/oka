import 'package:meta/meta.dart';

/// Optional executable run on leader `term` before group SIGTERM+SIGCONT (p1).
///
/// Invoked as `<executable> <marker>` with `BOUNDED_SESSION_MARKER` set.
/// Success is never settlement evidence.
@immutable
final class GracefulCleanupHook {
  const GracefulCleanupHook({
    required this.executable,
    this.timeout = const Duration(seconds: 2),
  });

  final String executable;

  /// Whole seconds passed to `--graceful-timeout` (default **2**).
  final Duration timeout;
}
