/// Bounded log capture — the day-one evidence surface every surveyed
/// system hand-rolled (ring buffers of 40 to 4000 lines).
///
/// Consumers assert with [waitFor] instead of sleep-and-grep; the timeout
/// message embeds the tail so failures are debuggable without re-running.
library;

import 'dart:async';

/// A bounded, broadcast log tap: lines in, ring buffer + live stream out.
final class LogTap {
  LogTap({this.maxLines = 4000, this.name});

  /// Oldest lines are dropped beyond this bound.
  final int maxLines;

  /// Optional display name used in error messages.
  final String? name;

  final _buffer = <String>[];
  final _controller = StreamController<String>.broadcast();
  var _closed = false;

  /// Live stream of added lines (broadcast: any number of followers).
  Stream<String> get stream => _controller.stream;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  void add(final String line) {
    if (_closed) return;
    _buffer.add(line);
    if (_buffer.length > maxLines) _buffer.removeAt(0);
    _controller.add(line);
  }

  /// The last [n] lines (fewer when the buffer is younger).
  List<String> tail(final int n) {
    final start = _buffer.length > n ? _buffer.length - n : 0;
    return List.of(_buffer.sublist(start));
  }

  /// First buffered line matching [pattern], or null.
  String? firstMatch(final Pattern pattern) {
    for (final line in _buffer) {
      if (pattern.allMatches(line).isNotEmpty) return line;
    }
    return null;
  }

  /// How many buffered lines match [pattern].
  int count(final Pattern pattern) =>
      _buffer.where((final line) => pattern.allMatches(line).isNotEmpty).length;

  /// The first line matching [pattern] — from the buffer or the live
  /// stream — or a [TimeoutException] whose message embeds the tail.
  Future<String> waitFor(
    final Pattern pattern, {
    required final Duration timeout,
    final Duration pollInterval = const Duration(milliseconds: 50),
  }) async {
    final buffered = firstMatch(pattern);
    if (buffered != null) return buffered;

    final completer = Completer<String>();
    late final StreamSubscription<String> sub;
    sub = stream.listen((final line) {
      if (!completer.isCompleted && pattern.allMatches(line).isNotEmpty) {
        completer.complete(line);
      }
    });
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          TimeoutException(
            'No line matching $pattern within ${timeout.inMilliseconds}ms '
            'on ${name ?? 'tap'}; last lines:\n${tail(15).join('\n')}',
            timeout,
          ),
        );
      }
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      await sub.cancel();
    }
  }

  /// Fails pending waiters and stops accepting lines. Buffered lines stay
  /// readable ([tail], [firstMatch]).
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}
