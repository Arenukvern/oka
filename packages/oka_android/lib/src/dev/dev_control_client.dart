/// Loopback JSON-lines client for the owning `oka dev` delegation channel
/// (`DevControlServer`, ADR-0011).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The server accepted the command but the TCP reply line was lost (EOF).
final class DevControlReplyLost implements Exception {
  DevControlReplyLost([this.message = 'control channel closed before reply']);
  final String message;
  @override
  String toString() => message;
}

/// Outcome of one control request (ack, lost reply, or timeout).
final class DevControlRequestResult {
  const DevControlRequestResult.acknowledged(this.response)
      : replyLost = false,
        timedOut = false;

  const DevControlRequestResult.replyLost()
      : response = null,
        replyLost = true,
        timedOut = false;

  const DevControlRequestResult.timedOut()
      : response = null,
        replyLost = false,
        timedOut = true;

  final Map<String, Object?>? response;
  final bool replyLost;
  final bool timedOut;

  bool get ok => response?['ok'] == true;
}

/// A single JSON-line request/response on the session control port.
final class DevControlClient {
  DevControlClient._(this._socket) {
    _lines = StreamController<String>.broadcast(sync: true);
    _sub = _socket
        .map(utf8.decode)
        .transform(const LineSplitter())
        .listen(_lines.add);
    unawaited(
      _socket.done.whenComplete(() async {
        if (!_lines.isClosed) {
          await _lines.close();
        }
      }),
    );
  }

  final Socket _socket;
  late final StreamSubscription<String> _sub;
  late final StreamController<String> _lines;

  static Future<DevControlClient> connect({
    required int port,
    String host = '127.0.0.1',
    Duration connectTimeout = const Duration(seconds: 5),
  }) async {
    // ignore: close_sinks
    final socket = await Socket.connect(host, port).timeout(connectTimeout);
    return DevControlClient._(socket);
  }

  Future<DevControlRequestResult> request(
    Map<String, Object?> body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final waiter = Completer<DevControlRequestResult>();
    late final StreamSubscription<String> lineSub;
    lineSub = _lines.stream.listen(
      (line) {
        if (waiter.isCompleted) return;
        waiter.complete(
          DevControlRequestResult.acknowledged(
            jsonDecode(line) as Map<String, Object?>,
          ),
        );
        unawaited(lineSub.cancel());
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!waiter.isCompleted) {
          waiter.complete(const DevControlRequestResult.replyLost());
        }
        unawaited(lineSub.cancel());
      },
      onDone: () {
        if (!waiter.isCompleted) {
          waiter.complete(const DevControlRequestResult.replyLost());
        }
        unawaited(lineSub.cancel());
      },
    );
    unawaited(
      _socket.done.then((_) {
        if (!waiter.isCompleted) {
          waiter.complete(const DevControlRequestResult.replyLost());
        }
      }),
    );
    try {
      _socket.write('${jsonEncode(body)}\n');
      await _socket.flush();
    } on Object {
      if (!waiter.isCompleted) {
        waiter.complete(const DevControlRequestResult.replyLost());
      }
      return waiter.future;
    }
    try {
      return await waiter.future.timeout(
        timeout,
        onTimeout: () {
          if (!waiter.isCompleted) {
            waiter.complete(const DevControlRequestResult.timedOut());
          }
          return const DevControlRequestResult.timedOut();
        },
      );
    } finally {
      await lineSub.cancel();
    }
  }

  Future<DevControlRequestResult> requestQuit({
    int id = 1,
    Duration timeout = const Duration(seconds: 30),
  }) =>
      request({'id': id, 'method': 'quit'}, timeout: timeout);

  Future<DevControlRequestResult> requestDetach({
    int id = 1,
    Duration timeout = const Duration(seconds: 30),
  }) =>
      request({'id': id, 'method': 'detach'}, timeout: timeout);

  Future<void> close() async {
    await _sub.cancel();
    await _lines.close();
    _socket.destroy();
  }
}
