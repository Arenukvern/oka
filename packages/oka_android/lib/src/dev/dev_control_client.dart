/// Loopback JSON-lines client for the owning `oka dev` delegation channel
/// (`DevControlServer`, ADR-0011).
///
/// **Contract (read independently — do not assume SIGTERM runs Dart `finally`):**
/// * Request: `{"id": <int>, "method": "reload"|"restart"|"stop"|"quit"|"detach"|"status"}`.
/// * `stop` stops the app; the **session keeps running**.
/// * `quit` / `detach` end the owning session (writer clears discovery on exit).
/// * TCP `127.0.0.1` only; no auth.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A single JSON-line request/response on the session control port.
final class DevControlClient {
  DevControlClient._(this._socket) {
    _sub = _socket
        .map(utf8.decode)
        .transform(const LineSplitter())
        .listen(_pending.add);
  }

  final Socket _socket;
  late final StreamSubscription<String> _sub;
  final _pending = <String>[];

  /// Connects to the published `control_port` from
  /// `.flutter_mcp/runner-session.json`.
  static Future<DevControlClient> connect({
    required int port,
    String host = '127.0.0.1',
    Duration connectTimeout = const Duration(seconds: 5),
  }) async {
    // Caller owns the socket lifetime via [close].
    // ignore: close_sinks
    final socket = await Socket.connect(host, port).timeout(connectTimeout);
    return DevControlClient._(socket);
  }

  /// Sends one request and waits for the first response line (bounded).
  Future<Map<String, Object?>> request(
    Map<String, Object?> body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _pending.clear();
    _socket.write('${jsonEncode(body)}\n');
    final deadline = DateTime.now().add(timeout);
    while (_pending.isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('control channel response', timeout);
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return jsonDecode(_pending.first) as Map<String, Object?>;
  }

  /// Ends the owning session (`DevControlCommand.quit` on the server).
  Future<Map<String, Object?>> requestQuit({int id = 1}) =>
      request({'id': id, 'method': 'quit'});

  /// Detach: app keeps running, session ends.
  Future<Map<String, Object?>> requestDetach({int id = 1}) =>
      request({'id': id, 'method': 'detach'});

  Future<void> close() async {
    await _sub.cancel();
    _socket.destroy();
  }
}
