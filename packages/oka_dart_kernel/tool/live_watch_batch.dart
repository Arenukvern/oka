import 'dart:async';

/// Deduplicates a save burst without losing distinct libraries. Applies remain
/// serial, including saves arriving while an earlier batch is compiling.
class LiveWatchBatch {
  LiveWatchBatch({
    required this.apply,
    required this.onError,
    this.debounce = const Duration(milliseconds: 500),
  });

  final Future<void> Function(String path) apply;
  final void Function(String path, Object error, StackTrace stack) onError;
  final Duration debounce;
  final _pending = <String>{};
  Future<void> _inFlight = Future<void>.value();
  Timer? _timer;
  bool _closed = false;

  void schedule(String path) {
    if (_closed) throw StateError('live_watch_batch_closed');
    _pending.add(path);
    _timer?.cancel();
    _timer = Timer(debounce, flush);
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return;
    final batch = _pending.toList();
    _pending.clear();
    _inFlight = _inFlight.then((_) async {
      for (final path in batch) {
        try {
          await apply(path);
        } on Object catch (error, stack) {
          // A failed unit must not discard the other accepted save events.
          try {
            onError(path, error, stack);
          } on Object {
            // Reporting failure cannot poison the remaining batch either.
          }
        }
      }
    });
  }

  Future<void> close() async {
    _closed = true;
    flush();
    await _inFlight;
  }
}
