/// `oka dev` delegation channel (roadmap Now item): a loopback TCP
/// JSON-lines control server that lets out-of-process tools drive
/// reload / restart / stop through the OWNING dev session — the only
/// compile-capable channel (the flutter-tool daemon). Late-attach
/// VM-service reloads are silent no-ops (`ServiceRegistered` events never
/// replay already-registered services), so delegation is the only correct
/// path for the flutter MCP toolkit's `OkaDevSession` adapter and editors.
///
/// Contract (frozen; both sides implement to it):
///
/// * TCP, bound to `127.0.0.1` ONLY. **No auth** — a localhost-only dev
///   tool; anything on the machine may drive the session. Documented as
///   such everywhere this surface appears.
/// * JSON lines (`\n`-terminated). Request:
///   `{"id": <int>, "method": "reload"|"restart"|"stop"|"status"}`.
///   Response: `{"id": int, "ok": true, "result": {...}}` (angle brackets omitted) |
///   `{"id": <int>, "ok": false, "error": "<human-readable fix>"}`.
/// * reload/restart carry the ACTUAL daemon outcome (`fallback: true`
///   when the attach-mode restart fallback — relaunch + re-attach —
///   triggered). The connection may close on fallback/session end:
///   clients must handle EOF by re-reading
///   `.flutter_mcp/runner-session.json`.
/// * stop stops the app; the session keeps running.
/// * status answers from session metadata (no daemon round-trip).
/// * Unknown method / malformed JSON → per-id error response; the
///   connection stays open.
///
/// Lifecycle: started before [DevFlow.run] (from `oka dev --control-port`),
/// fed commands through [DevControlServer.onCommand] (the same
/// control stream the keyboard/stdin/watch sources share), fed session
/// outcomes through [DevControlServer.handleSessionResult] (wired to
/// [DevSession.onResult]), and closed after the flow ends on every exit
/// paths — alongside both discovery files (`vm.uri`,
/// `runner-session.json`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dev_session.dart';

/// Session metadata the `status` method answers from (no daemon
/// round-trip): what the session attached to, not what the app is doing.
class DevControlSessionInfo {
  const DevControlSessionInfo({
    required this.deviceId,
    required this.target,
    required this.mode,
  });

  /// Selected device serial (echoed by `status`).
  final String deviceId;

  /// Flutter entrypoint of the validated session manifest.
  final String target;

  /// Build mode of the validated session manifest (`debug`).
  final String mode;
}

/// One pending command awaiting the matching [DevSession] result event.
class _PendingRequest {
  _PendingRequest(this.event, this.completer, this.timer);

  /// The session event this request waits for
  /// (`reload.result` / `restart.result` / `restart.fallback` /
  /// `app.stopped`).
  final String event;

  /// Completed with the event data, or `null` on timeout / server close.
  final Completer<Map<String, Object?>?> completer;

  /// Shared bounded timeout (the session's `restart` includes the
  /// fallback relaunch, so it gets the widest window).
  final Timer timer;
}

/// The loopback JSON-lines control server (see the library doc). Bind is
/// localhost-only by construction (`InternetAddress.loopbackIPv4`); there
/// is **no auth** — this is a localhost-only dev tool, documented as such.
class DevControlServer {
  DevControlServer._(
    this._serverSocket,
    this.info,
    this._onCommand, {
    required this.reloadTimeout,
    required this.restartTimeout,
    required this.stopTimeout,
  });

  /// Bounded wait for a reload result (the daemon round-trip).
  final Duration reloadTimeout;

  /// Bounded wait for a restart result *including* the fallback path
  /// (stop mid-restart → relaunch → re-attach).
  final Duration restartTimeout;

  /// Bounded wait for `app.stopped`.
  final Duration stopTimeout;

  final ServerSocket _serverSocket;
  final DevControlSessionInfo info;
  final void Function(DevControlCommand command) _onCommand;

  final _clients = <Socket>{};
  final _pending = <String, List<_PendingRequest>>{};
  bool _closed = false;

  /// The chosen (possibly ephemeral) control port — published only via
  /// `.flutter_mcp/runner-session.json` (`control_port`).
  int get port => _serverSocket.port;

  /// Bind host (always loopback).
  String get host => _serverSocket.address.host;

  /// Binds `127.0.0.1:<port>` (port 0 → ephemeral; the chosen port is only
  /// known via [port] → runner-session.json) and starts accepting clients.
  static Future<DevControlServer> start({
    required final DevControlSessionInfo info,
    required final void Function(DevControlCommand command) onCommand,
    final int port = 0,
    final Duration reloadTimeout = const Duration(seconds: 30),
    final Duration restartTimeout = const Duration(seconds: 60),
    final Duration stopTimeout = const Duration(seconds: 30),
  }) async {
    final serverSocket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    final server = DevControlServer._(
      serverSocket,
      info,
      onCommand,
      reloadTimeout: reloadTimeout,
      restartTimeout: restartTimeout,
      stopTimeout: stopTimeout,
    ).._accept();
    return server;
  }

  void _accept() {
    _serverSocket.listen((final socket) {
      _clients.add(socket);
      socket
          .map(utf8.decode)
          .transform(const LineSplitter())
          .listen(
            (final line) => _handleLine(line, socket),
            onDone: () => _clients.remove(socket),
            onError: (final Object _) => _clients.remove(socket),
          );
    });
  }

  /// Feeds a [DevSession] result event into this server (wire to
  /// [DevSession.onResult]). Completes every pending request waiting on
  /// that event with the real outcome data.
  void handleSessionResult(
    final String event,
    final Map<String, Object?> data,
  ) {
    final waiting = _pending.remove(event);
    if (waiting == null) return;
    for (final p in waiting) {
      p.timer.cancel();
      if (!p.completer.isCompleted) p.completer.complete(data);
    }
  }

  /// Closes the server and every client socket (flow end — all exit
  /// paths). Pending requests are released (their handlers observe
  /// `null` and stay silent on the destroyed sockets).
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values.expand((final l) => l)) {
      pending.timer.cancel();
      if (!pending.completer.isCompleted) pending.completer.complete(null);
    }
    _pending.clear();
    for (final socket in _clients.toList()) {
      _clients.remove(socket);
      try {
        socket.destroy();
      } on SocketException {
        // already gone — fine.
      }
    }
    await _serverSocket.close();
  }

  // -- Request handling ------------------------------------------------------

  void _handleLine(final String rawLine, final Socket socket) {
    final line = rawLine.trim();
    if (line.isEmpty || _closed) return;

    Map<String, Object?>? request;
    var malformed = false;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map) {
        request = decoded.cast<String, Object?>();
      } else {
        malformed = true;
      }
    } on FormatException {
      malformed = true;
    }

    if (malformed || request == null) {
      _respond(socket, {
        'id': -1,
        'ok': false,
        'error':
            'Malformed request (expected one JSON object per line: '
            '{"id": <int>, "method": "reload"|"restart"|"stop"|"status"}) '
            '— connection stays open; re-send a valid request.',
      });
      return;
    }

    final rawId = request['id'];
    final id = rawId is int ? rawId : -1;
    final method = request['method'];
    if (method is! String || method.trim().isEmpty) {
      _respond(socket, {
        'id': id,
        'ok': false,
        'error':
            'Missing or non-string "method" — expected one of '
            'reload | restart | stop | status.',
      });
      return;
    }

    switch (method.trim()) {
      case 'status':
        _respond(socket, {
          'id': id,
          'ok': true,
          'result': {
            'session': 'ready',
            'device': info.deviceId,
            'target': info.target,
            'mode': info.mode,
          },
        });
      case 'reload' || 'restart' || 'stop':
        unawaited(_handleOperation(method.trim(), id, socket));
      default:
        _respond(socket, {
          'id': id,
          'ok': false,
          'error':
              "Unknown method '$method' — expected one of "
              'reload | restart | stop | status.',
        });
    }
  }

  /// Maps one control method to a [DevControlCommand], waits (bounded) for
  /// the matching session result event, and answers with the real daemon
  /// outcome. The command goes through the same shared control stream the
  /// keyboard / stdin / watch sources use — the server never touches the
  /// daemon wire itself.
  Future<void> _handleOperation(
    final String method,
    final int id,
    final Socket socket,
  ) async {
    final (command, events, timeout) = switch (method) {
      'reload' => (
        DevControlCommand.reload,
        const ['reload.result'],
        reloadTimeout,
      ),
      'restart' => (
        DevControlCommand.restart,
        const ['restart.result', 'restart.fallback'],
        restartTimeout,
      ),
      _ => (
        DevControlCommand.stopApp,
        const ['app.stopped'],
        stopTimeout,
      ),
    };

    final completers = {
      for (final e in events) e: Completer<Map<String, Object?>?>(),
    };
    final timer = Timer(timeout, () {
      for (final c in completers.values) {
        if (!c.isCompleted) c.complete(null);
      }
    });
    final pendings = [
      for (final entry in completers.entries)
        _PendingRequest(entry.key, entry.value, timer),
    ];
    for (final p in pendings) {
      _pending.putIfAbsent(p.event, () => []).add(p);
    }

    _onCommand(command);
    try {
      final (event, data) =
          await Future.any([
            for (final entry in completers.entries)
              entry.value.future.then((final d) => (entry.key, d)),
          ]);
      if (data == null) {
        _respond(socket, {
          'id': id,
          'ok': false,
          'error':
              '$method sent no result within ${timeout.inSeconds}s — the '
              'owning `oka dev` session may have ended or is stuck. '
              'Re-read .flutter_mcp/runner-session.json (a fresh session '
              'owns a new endpoint); if its pid is gone, re-run `oka dev`.',
        });
        return;
      }
      _respond(socket, _outcomeResponse(method, event, id, data));
    } finally {
      timer.cancel();
      for (final p in pendings) {
        _pending[p.event]?.remove(p);
        if (_pending[p.event]?.isEmpty ?? false) _pending.remove(p.event);
      }
    }
  }

  /// Builds the contract response for one session outcome:
  /// the ACTUAL daemon result, with `fallback: true` when the attach-mode
  /// restart fallback (relaunch + re-attach) triggered.
  Map<String, Object?> _outcomeResponse(
    final String method,
    final String event,
    final int id,
    final Map<String, Object?> data,
  ) {
    switch (event) {
      case 'restart.fallback':
        return {
          'id': id,
          'ok': false,
          'fallback': true,
          'error':
              'The app stopped during hot restart (attach-mode limitation '
              'on this device) — `oka dev` is relaunching and re-attaching. '
              'Wait for the new session, then re-read '
              '.flutter_mcp/runner-session.json for the new vm_service_uri.',
        };
      case 'app.stopped':
        // The event itself is the success signal (stop is fire-and-forget
        // on the session side).
        return {'id': id, 'ok': true, 'result': <String, Object?>{}};
      default:
        final ok = data['ok'] == true;
        if (ok) {
          return {
            'id': id,
            'ok': true,
            'result': {...data}..remove('ok'),
          };
        }
        final fix = switch (method) {
          'reload' =>
            'Hot reload failed — check the `oka dev` output for the '
                'compile error (most often a Dart error in the edited '
                'file), fix it, then re-send reload.',
          _ =>
            'The session reports the operation failed — check the '
                '`oka dev` output for the daemon error, resolve it, then '
                'retry.',
        };
        return {'id': id, 'ok': false, 'error': fix};
    }
  }

  void _respond(final Socket socket, final Map<String, Object?> response) {
    if (_closed || !_clients.contains(socket)) return;
    try {
      socket.write('${jsonEncode(response)}\n');
    } on SocketException {
      // Client went away mid-request — nothing to answer.
    }
  }
}
