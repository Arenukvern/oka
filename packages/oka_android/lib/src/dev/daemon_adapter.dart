/// flutter_tools daemon adapter (ADR-0011 H3).
///
/// This file is the **only** code allowed to know daemon wire details
/// (ADR-0011 gotchas): everything above it speaks [DaemonEvent] /
/// [DaemonResponse], never JSON lines.
///
/// Protocol facts pinned by the H0 live probe (see
/// `docs/guides/hot_reload_plan.mdx`, H0 evidence block):
///
/// * Spawned as `<recorded-sdk>/bin/flutter attach --machine -d <id>` —
///   the binary always comes from the session manifest's SDK path, never
///   ambient PATH (flag parity, ADR-0011 §4).
/// * Every stdout message is a **single-element JSON array**:
///   `[{"event": "...", "params": {...}}]` for events,
///   `[{"id": N, "result"/"error": ...}]` for responses. Bare JSON objects
///   and non-JSON chatter lines are tolerated (feature-detect).
/// * `daemon.connected` (version 0.6.1 on the probed SDK) arrives first;
///   `app.start` (`launchMode: attach`) announces the session and carries
///   the `appId` all app-domain commands require; commands are sent only
///   **after** `app.start`.
/// * Events seen in the probe: `app.start`, `app.debugPort` (usable
///   `wsUri`), `app.devTools`, `app.dtd`, `app.progress` (`progressId`,
///   `finished`), `app.started`. Errors arrive as response-level `error`.
///   **Unknown events and unknown fields are ignored** — the protocol is
///   not semver'd (ADR-0011 §2).
/// * Commands (live-probed 2026-09-07 against flutter_tools 3.47.0-0.4.pre,
///   daemon.dart AppDomain registers only restart/stop/detach/
///   callServiceExtension): **hot reload = `app.restart` with
///   `{appId, fullRestart: false}`**; **hot restart = `app.restart` with
///   `{appId, fullRestart: true}`**; `app.stop {appId}`; `app.detach
///   {appId}`; `daemon.shutdown` (daemon domain, no appId). The H0
///   probe's `app.reload` spelling does **not** exist in this SDK — the
///   adapter feature-detects it as a fallback for older layouts.
///
/// The transport is injectable so protocol tests run against scripted
/// stdio fixtures — no real flutter binary, no device (see
/// `test/adr0011_daemon_adapter_test.dart`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One daemon event (`[{"event": name, "params": {...}}]`).
class DaemonEvent {
  const DaemonEvent(this.event, {this.params = const {}});

  /// Event name, e.g. `app.start`, `app.progress`, `app.started`.
  final String event;

  /// Event parameters. Unknown fields are preserved here but never
  /// interpreted (feature-detect).
  final Map<String, Object?> params;

  Object? field(final String key) => params[key];

  @override
  String toString() => 'DaemonEvent($event, $params)';
}

/// A response to a sent command (`[{"id": N, "result"| "error": ...}]`).
class DaemonResponse {
  const DaemonResponse({required this.id, this.result, this.error});

  final int id;
  final Object? result;
  final Object? error;

  bool get ok => error == null;

  /// Human-readable error text (feature-detect: string or object).
  String get errorText {
    final e = error;
    if (e is String) return e;
    if (e is Map) {
      final msg = e['message'] ?? e['error'];
      if (msg != null) return msg.toString();
    }
    return e?.toString() ?? 'unknown daemon error';
  }
}

/// Thrown on protocol-level failures (timeout, dead daemon, error response
/// when the caller asked [FlutterDaemonAdapter.send] to enforce ok).
class DaemonException implements Exception {
  DaemonException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Narrow process seam for the adapter: everything [FlutterDaemonAdapter]
/// needs from the spawned `flutter attach --machine` process. Injectable so
/// tests feed a scripted fake instead of a real process.
abstract class DaemonTransport {
  /// Daemon stdout (JSON lines, possibly interleaved with chatter).
  Stream<List<int>> get stdout;

  /// Daemon stderr (diagnostics; never the protocol).
  Stream<List<int>> get stderr;

  /// Completes when the daemon process exits.
  Future<int> get exitCode;

  /// Writes one line to the daemon's stdin (a command; no newline needed).
  void writeLine(final String line);

  /// Kills the daemon process (detach/quit cleanup).
  bool kill();
}

/// Real-process transport over `Process.start(...)`.
class ProcessDaemonTransport implements DaemonTransport {
  ProcessDaemonTransport(this._process);

  final Process _process;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void writeLine(final String line) {
    _process.stdin.writeln(line);
  }

  @override
  bool kill() => _process.kill();
}

/// Pure argv builder for the attach spawn (unit-tested; the executor is
/// [spawnAttachDaemon]).
List<String> flutterAttachMachineArgs({required final String deviceId}) => [
  'attach',
  '--machine',
  '-d',
  deviceId,
];

/// Spawns `<flutterBinary> attach --machine -d <deviceId>` and returns the
/// transport. [flutterBinary] must be the session manifest's recorded-SDK
/// binary (never PATH) — the caller enforces that via `checkDevSession`.
///
/// [adbPath] (the oka-resolved platform-tools binary) is prepended to the
/// child's PATH: the flutter tool discovers devices through `adb`, and the
/// oka-managed SDK dir is often not on the ambient PATH (live e2e finding,
/// 2026-09-07 — without this, attach reports "No supported devices found").
Future<DaemonTransport> spawnAttachDaemon({
  required final String flutterBinary,
  required final String deviceId,
  final String? adbPath,
}) async {
  final environment = <String, String>{...Platform.environment};
  if (adbPath != null && adbPath.isNotEmpty) {
    final dir = p.dirname(adbPath);
    environment['PATH'] = '$dir:${environment['PATH'] ?? ''}';
  }
  final process = await Process.start(
    flutterBinary,
    flutterAttachMachineArgs(deviceId: deviceId),
    environment: environment,
  );
  return ProcessDaemonTransport(process);
}

/// The daemon protocol adapter: parses stdout into typed
/// [DaemonEvent]s/[DaemonResponse]s, gates commands behind `app.start`,
/// and exposes `reload` / `restart` / `stop` / `shutdown`.
class FlutterDaemonAdapter {
  FlutterDaemonAdapter({
    required final DaemonTransport transport,
    this.verbose = false,
    this.onChatter,
  }) : _transport = transport {
    _subscriptions.add(
      transport.stdout.transform(utf8.decoder).listen(_onStdoutData),
    );
    _subscriptions.add(
      transport.stderr.transform(utf8.decoder).listen(_onStderrData),
    );
    _subscriptions.add(
      transport.exitCode.then(_onExit).asStream().listen((_) {}),
    );
  }

  final DaemonTransport _transport;
  final bool verbose;
  final void Function(String line)? onChatter;

  final _events = StreamController<DaemonEvent>.broadcast();
  final _subscriptions = <StreamSubscription<void>>[];
  final _pending = <int, Completer<DaemonResponse>>{};
  final _seen = <String, DaemonEvent>{};

  var _nextId = 1;
  var _exited = false;
  Completer<void>? _appStart;

  /// All daemon events (broadcast — multiple consumers allowed).
  Stream<DaemonEvent> get events => _events.stream;

  /// Whether the daemon announced `app.start` (attach session accepted).
  bool get appStartReceived => _seen.containsKey('app.start');

  /// The daemon's app-instance id (from `app.start`) — required by every
  /// app-domain command (`app.restart` / `app.stop` / `app.detach`).
  String? get appId => lastEvent('app.start')?.field('appId') as String?;

  /// Whether the daemon process has exited.
  bool get exited => _exited;

  /// Completes when the daemon process exits.
  Future<int> get exitCode => _transport.exitCode;

  /// The latest event of [name], or null (feature-detect accessor).
  DaemonEvent? lastEvent(final String name) => _seen[name];

  /// The `wsUri` from the newest `app.debugPort` event, or null.
  String? get wsUri => lastEvent('app.debugPort')?.field('wsUri') as String?;

  /// Daemon version from `daemon.connected`, or null.
  String? get daemonVersion =>
      lastEvent('daemon.connected')?.field('version') as String?;

  // -- Inbound ---------------------------------------------------------------

  void _onStdoutData(final String chunk) =>
      chunk.split('\n').forEach(_handleLine);

  void _onStderrData(final String chunk) {
    if (!verbose) return;
    for (final line in chunk.split('\n')) {
      final t = line.trim();
      if (t.isNotEmpty) onChatter?.call('[daemon:err] $t');
    }
  }

  void _onExit(final int code) {
    _exited = true;
    _failAllPending('flutter attach exited (code $code)');
    if (!_events.isClosed) unawaited(_events.close());
  }

  /// Handles one stdout line. Single-element JSON arrays are the pinned
  /// protocol shape; bare JSON objects and chatter are tolerated
  /// (feature-detect, ADR-0011 §2).
  void _handleLine(final String raw) {
    final line = raw.trim();
    if (line.isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      _chatter(raw);
      return;
    }
    final List<Object?> items;
    if (decoded is List) {
      items = decoded;
    } else if (decoded is Map) {
      items = [decoded]; // tolerate bare objects (feature-detect)
    } else {
      _chatter(raw);
      return;
    }
    for (final item in items) {
      if (item is! Map) {
        _chatter(raw);
        continue;
      }
      if (item['event'] is String) {
        _handleEvent(
          DaemonEvent(
            item['event'] as String,
            params: item['params'] is Map
                ? (item['params'] as Map<Object?, Object?>)
                      .cast<String, Object?>()
                : const {},
          ),
        );
      } else if (item['id'] is int) {
        _handleResponse(item);
      } else {
        _chatter(raw);
      }
    }
  }

  void _handleEvent(final DaemonEvent event) {
    final firstOfKind = !_seen.containsKey(event.event);
    _seen[event.event] = event;
    if (event.event == 'app.start' && firstOfKind) {
      _appStart?.complete();
      _appStart = null;
    }
    if (verbose) _chatter('[daemon] $event');
    if (!_events.isClosed) _events.add(event);
  }

  void _handleResponse(final Map<Object?, Object?> item) {
    final id = item['id']! as int;
    final pending = _pending.remove(id);
    final response = DaemonResponse(
      id: id,
      result: item['result'],
      error: item['error'],
    );
    if (pending != null && !pending.isCompleted) {
      pending.complete(response);
    }
  }

  void _chatter(final String line) {
    if (verbose) onChatter?.call(line);
  }

  // -- Outbound ---------------------------------------------------------------

  /// Waits (bounded) for the daemon's `app.start` event — commands are sent
  /// only after it (protocol fact pinned in H0). Throws [DaemonException]
  /// on timeout or daemon exit.
  Future<void> waitAppStart({
    final Duration timeout = const Duration(seconds: 90),
  }) async {
    if (appStartReceived) return;
    if (_exited) {
      throw DaemonException('flutter attach exited before app.start');
    }
    final completer = _appStart ??= Completer<void>();
    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      if (!completer.isCompleted) completer.complete();
    });
    try {
      await completer.future;
    } finally {
      timer.cancel();
    }
    if (!appStartReceived) {
      throw DaemonException(
        timedOut
            ? 'flutter attach did not announce app.start within '
                  '${timeout.inSeconds}s — is a debug build running on the device?'
            : 'flutter attach exited before app.start',
      );
    }
  }

  /// Sends [method] with [params], waiting for the matching response.
  /// Commands are gated behind `app.start` per the pinned protocol facts.
  Future<DaemonResponse> send(
    final String method, {
    final Map<String, Object?> params = const {},
    final Duration timeout = const Duration(seconds: 60),
  }) async {
    if (_exited) {
      throw DaemonException('cannot send $method — flutter attach exited');
    }
    if (!appStartReceived) {
      // Buffer until app.start rather than racing the daemon.
      await waitAppStart();
    }
    final id = _nextId++;
    final completer = _pending[id] = Completer<DaemonResponse>();
    _transport.writeLine(
      jsonEncode([
        {'id': id, 'method': method, 'params': params},
      ]),
    );
    final response = await completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw DaemonException(
          'daemon did not answer $method within ${timeout.inSeconds}s',
        );
      },
    );
    return response;
  }

  /// Hot reload — Dart-only changes. Live-probed interface: `app.restart`
  /// with `fullRestart: false` (no `app.reload` method exists in the
  /// probed SDK; feature-detected as a fallback for older layouts).
  Future<DaemonResponse> reload() => _appOperation(fullRestart: false);

  /// Hot restart — full non-incremental kernel compile + app restart
  /// (`app.restart` with `fullRestart: true`; flutter_tools semantics;
  /// state loss documented in H5). There is no `_flutter.hotRestart` RPC.
  Future<DaemonResponse> restart() => _appOperation(fullRestart: true);

  Future<DaemonResponse> _appOperation({
    required final bool fullRestart,
  }) async {
    // Gate commands behind app.start first — the appId arrives with it.
    if (!appStartReceived) await waitAppStart();
    final id = appId;
    if (id == null || id.isEmpty) {
      throw DaemonException(
        'cannot ${fullRestart ? 'hot-restart' : 'hot-reload'} — the daemon '
        'has not announced an appId (no app.start event yet)',
      );
    }
    final response = await send(
      'app.restart',
      params: {'appId': id, 'fullRestart': fullRestart},
    );
    // Feature-detect (protocol not semver'd): older SDKs exposed hot
    // reload as its own `app.reload` method instead of the
    // `fullRestart: false` spelling.
    if (!response.ok &&
        response.errorText.contains('command not understood: app.restart')) {
      return send(
        fullRestart ? 'app.hotRestart' : 'app.reload',
        params: {'appId': id},
      );
    }
    return response;
  }

  /// Stops the running app (`app.stop`, appId required).
  Future<DaemonResponse> stopApp() async {
    if (!appStartReceived) await waitAppStart();
    final id = appId;
    return send(
      'app.stop',
      params: {if (id != null && id.isNotEmpty) 'appId': id},
    );
  }

  /// Detaches from the running app (`app.detach`, appId required) — the
  /// app keeps running; the daemon session ends.
  Future<DaemonResponse> detachApp() async {
    if (!appStartReceived) await waitAppStart();
    final id = appId;
    return send(
      'app.detach',
      params: {if (id != null && id.isNotEmpty) 'appId': id},
    );
  }

  /// Shuts the daemon down (`daemon.shutdown`); the attach process exits.
  Future<DaemonResponse> shutdown() => send('daemon.shutdown');

  /// Fire-and-forget shutdown + process kill (cleanup path that must never
  /// throw out of a session tear-down).
  void dispose() {
    if (!_exited) {
      try {
        _transport.writeLine(
          jsonEncode([
            {'id': _nextId++, 'method': 'daemon.shutdown'},
          ]),
        );
      } on Exception {
        // Daemon already gone — kill below is the backstop.
      }
      _transport.kill();
    }
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    if (!_events.isClosed) unawaited(_events.close());
  }

  void _failAllPending(final String why) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(DaemonException(why));
    }
    _pending.clear();
  }
}
