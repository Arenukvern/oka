/// Single-flight coordinator for subreaper settle work (SIGTERM + child exit).
final class LinuxSubreaperSettleCoordinator {
  Future<bool>? _flight;

  /// Runs [settle] at most once; concurrent callers await the same future.
  Future<bool> settleOnce(Future<bool> Function() settle) {
    final existing = _flight;
    if (existing != null) return existing;
    final started = settle();
    _flight = started;
    return started;
  }
}
