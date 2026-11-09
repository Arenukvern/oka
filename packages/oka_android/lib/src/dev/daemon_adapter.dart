/// flutter_tools daemon adapter (ADR-0011 H3).
///
/// This file is the **only** code allowed to know daemon wire details
/// (ADR-0011 gotchas): everything above it speaks [DaemonEvent] /
/// [DaemonResponse], never JSON lines.
///
/// Protocol facts pinned by the H0 live probe (see
/// `docs/archive/hot_reload_plan.mdx`, H0 evidence block):
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

import 'dev_session_teardown_budget.dart';

/// One daemon event (`[{"event": name, "params": {...}}]`).
class DaemonEvent {
  const DaemonEvent(this.event, {this.params = const {}});

  /// Event name, e.g. `app.start`, `app.progress`, `app.started`.
  final String event;

  /// Event parameters. Unknown fields are preserved here but never
  /// interpreted (feature-detect).
  final Map<String, Object?> params;

  Object? field(String key) => params[key];

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

/// Why attach startup ended before `app.started`.
enum AttachHandshakeFailure {
  appStopBeforeStarted,
  daemonExitedBeforeStarted,
  timedOut,
}

/// One machine-protocol event in arrival order (duplicates retained).
final class MachineEventRingEntry {
  const MachineEventRingEntry({
    required this.event,
    required this.atUtc,
    required this.params,
    this.paramsTruncated = false,
  });

  final String event;
  final String atUtc;
  final Map<String, Object?> params;
  final bool paramsTruncated;

  Map<String, Object?> toJson() => {
    'event': event,
    'atUtc': atUtc,
    'params': params,
    if (paramsTruncated) 'paramsTruncated': true,
  };
}

/// Outcome of [FlutterDaemonAdapter.disposeGracefully] (bounded attach exit).
final class DaemonDisposeReport {
  const DaemonDisposeReport({
    required this.shutdownAttempted,
    required this.shutdownAcknowledged,
    required this.processExited,
    required this.killedAsBackstop,
    this.message,
  });

  final bool shutdownAttempted;
  final bool shutdownAcknowledged;
  final bool processExited;
  final bool killedAsBackstop;
  final String? message;
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
  void writeLine(String line);

  /// Kills the daemon process (detach/quit cleanup).
  bool kill();
}

/// Real-process transport over `Process.start(...)`.
class ProcessDaemonTransport implements DaemonTransport {
  ProcessDaemonTransport(this._process) : startedAt = DateTime.now();

  final Process _process;
  final DateTime startedAt;

  /// Host pid of `flutter attach --machine` (record before parent exit).
  int get pid => _process.pid;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void writeLine(String line) {
    _process.stdin.writeln(line);
  }

  @override
  bool kill() => _process.kill();
}

/// Default `--dds-port` when oka already created `adb forward tcp:<host> …`.
///
/// Flutter 3.47+ (`flutter_command.dart` `ddsPort` / `hostVmservicePort` on
/// stable-3.47.5): without an explicit `--dds-port`, DDS binds
/// `--host-vmservice-port`, which collides with an existing forward (`Address
/// already in use` on loopback). Parsed `--dds-port 0` keeps the host port for
/// the forward and lets DDS pick a free port (native f9/a92 pre-proof).
const attachDdsPortWhenOkaOwnsHostForward = 0;

/// Pure argv builder for the attach spawn (unit-tested; the executor is
/// [spawnAttachDaemon]).
///
/// When oka already owns an adb forward on [hostVmServicePort], pass
/// [deviceVmServicePort] and [hostVmServicePort] with an explicit
/// [ddsPort] (default [attachDdsPortWhenOkaOwnsHostForward]) — do not pass
/// `--debug-url` with the device logcat URI in that mode.
List<String> flutterAttachMachineArgs({
  required String deviceId,
  int? deviceVmServicePort,
  int? hostVmServicePort,
  int? ddsPort,
}) {
  final hostForward =
      hostVmServicePort != null && hostVmServicePort > 0 ? hostVmServicePort : null;
  final effectiveDds = hostForward != null
      ? (ddsPort ?? attachDdsPortWhenOkaOwnsHostForward)
      : ddsPort;
  return [
    'attach',
    '--machine',
    '-d',
    deviceId,
    if (deviceVmServicePort != null && deviceVmServicePort > 0) ...[
      '--device-vmservice-port',
      '$deviceVmServicePort',
    ],
    if (hostForward != null) ...[
      '--host-vmservice-port',
      '$hostForward',
      if (effectiveDds != null) ...[
        '--dds-port',
        '$effectiveDds',
      ],
    ],
  ];
}

/// Spawns `<flutterBinary> attach --machine -d <deviceId>` and returns the
/// transport. [flutterBinary] must be the session manifest's recorded-SDK
/// binary (never PATH) — the caller enforces that via `checkDevSession`.
///
/// [adbPath] (the oka-resolved platform-tools binary) is prepended to the
/// child's PATH: the flutter tool discovers devices through `adb`, and the
/// oka-managed SDK dir is often not on the ambient PATH (live e2e finding,
/// 2026-09-07 — without this, attach reports "No supported devices found").
Future<DaemonTransport> spawnAttachDaemon({
  required String flutterBinary,
  required String deviceId,
  String? adbPath,
  int? deviceVmServicePort,
  int? hostVmServicePort,
  int? ddsPort,
}) async {
  final environment = <String, String>{...Platform.environment};
  if (adbPath != null && adbPath.isNotEmpty) {
    final dir = p.dirname(adbPath);
    environment['PATH'] = '$dir:${environment['PATH'] ?? ''}';
  }
  final process = await Process.start(
    flutterBinary,
    flutterAttachMachineArgs(
      deviceId: deviceId,
      deviceVmServicePort: deviceVmServicePort,
      hostVmServicePort: hostVmServicePort,
      ddsPort: ddsPort,
    ),
    environment: environment,
  );
  return ProcessDaemonTransport(process);
}

/// The daemon protocol adapter: parses stdout into typed
/// [DaemonEvent]s/[DaemonResponse]s, gates commands behind `app.start`,
/// and exposes `reload` / `restart` / `stop` / `shutdown`.
class FlutterDaemonAdapter {
  FlutterDaemonAdapter({
    required DaemonTransport transport,
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
  var _stopAfterStartBeforeStarted = false;

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
  DaemonEvent? lastEvent(String name) => _seen[name];

  /// The `wsUri` from the newest `app.debugPort` event, or null.
  String? get wsUri => lastEvent('app.debugPort')?.field('wsUri') as String?;

  /// Daemon version from `daemon.connected`, or null.
  String? get daemonVersion =>
      lastEvent('daemon.connected')?.field('version') as String?;

  // -- Inbound ---------------------------------------------------------------

  void _onStdoutData(String chunk) =>
      chunk.split('\n').forEach(_handleLine);

  final _stderrRing = <String>[];
  static const _stderrRingMaxLines = 80;
  static const _stderrRingMaxBytes = 16 * 1024;
  var _stderrRingBytes = 0;

  final _eventRing = <MachineEventRingEntry>[];
  static const _eventRingMaxEntries = 64;
  static const _eventRingMaxBytes = 32 * 1024;
  static const _eventRingMaxSingleBytes = 4096;
  var _eventRingBytes = 0;

  /// Recent attach process stderr (for failure diagnostics).
  List<String> get stderrTail => List<String>.unmodifiable(_stderrRing);

  /// Machine events in arrival order (duplicates retained).
  List<Map<String, Object?>> snapshotMachineEventRing() =>
      _eventRing.map((e) => e.toJson()).toList(growable: false);

  bool get appStartedReceived => _seen.containsKey('app.started');

  bool get stopAfterStartBeforeStarted => _stopAfterStartBeforeStarted;

  /// State precheck for [waitForAppStarted] (handles same-chunk delivery).
  AttachHandshakeFailure? precheckAttachHandshakeFailure() {
    if (appStartedReceived) return null;
    if (_exited) return AttachHandshakeFailure.daemonExitedBeforeStarted;
    if (_stopAfterStartBeforeStarted) {
      return AttachHandshakeFailure.appStopBeforeStarted;
    }
    return null;
  }

  bool _isStopFatalBeforeStarted(DaemonEvent event) {
    if (appStartedReceived || !appStartReceived) return false;
    if (event.event != 'app.stop') return false;
    final startId = appId;
    final stopId = event.field('appId') as String?;
    if (startId != null &&
        stopId != null &&
        stopId.isNotEmpty &&
        startId != stopId) {
      return false;
    }
    return true;
  }

  static String _truncateUtf8(String input, int maxBytes) {
    final units = utf8.encode(input);
    if (units.length <= maxBytes) return input;
    var end = maxBytes.clamp(0, units.length);
    while (end > 0 && (units[end] & 0xC0) == 0x80) {
      end--;
    }
    if (end == 0) return '';
    return utf8.decode(units.sublist(0, end), allowMalformed: true);
  }

  void _appendEventRing(DaemonEvent event) {
    final at = DateTime.now().toUtc().toIso8601String();
    var params = Map<String, Object?>.from(event.params);
    MachineEventRingEntry entry = MachineEventRingEntry(
      event: event.event,
      atUtc: at,
      params: params,
    );
    var encoded = utf8.encode(jsonEncode(entry.toJson()));
    if (encoded.length > _eventRingMaxSingleBytes) {
      var preview = jsonEncode(params);
      var maxPreview = _eventRingMaxSingleBytes ~/ 2;
      for (var attempt = 0; attempt < 8; attempt++) {
        preview = _truncateUtf8(preview, maxPreview);
        params = {
          '_truncated': true,
          'preview': preview,
        };
        entry = MachineEventRingEntry(
          event: event.event,
          atUtc: at,
          params: params,
          paramsTruncated: true,
        );
        encoded = utf8.encode(jsonEncode(entry.toJson()));
        if (encoded.length <= _eventRingMaxSingleBytes) break;
        maxPreview ~/= 2;
      }
      if (encoded.length > _eventRingMaxSingleBytes) {
        final shortEvent = _truncateUtf8(event.event, 96);
        entry = MachineEventRingEntry(
          event: shortEvent,
          atUtc: at,
          params: const {
            '_truncated': true,
            '_eventNameTruncated': true,
          },
          paramsTruncated: true,
        );
        encoded = utf8.encode(jsonEncode(entry.toJson()));
        if (encoded.length > _eventRingMaxSingleBytes) {
          entry = MachineEventRingEntry(
            event: 'app.overflow',
            atUtc: at,
            params: const {'_truncated': true},
            paramsTruncated: true,
          );
          encoded = utf8.encode(jsonEncode(entry.toJson()));
        }
      }
    }
    _eventRing.add(entry);
    _eventRingBytes += encoded.length;
    while (_eventRing.length > _eventRingMaxEntries ||
        _eventRingBytes > _eventRingMaxBytes) {
      final removed = _eventRing.removeAt(0);
      _eventRingBytes -= utf8.encode(jsonEncode(removed.toJson())).length;
      if (_eventRingBytes < 0) _eventRingBytes = 0;
    }
  }

  void _onStderrData(String chunk) {
    for (final line in chunk.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final bytes = utf8.encode(t).length + 1;
      _stderrRing.add(t);
      _stderrRingBytes += bytes;
      while (_stderrRing.length > _stderrRingMaxLines ||
          _stderrRingBytes > _stderrRingMaxBytes) {
        final dropped = _stderrRing.removeAt(0);
        _stderrRingBytes -= utf8.encode(dropped).length + 1;
        if (_stderrRingBytes < 0) _stderrRingBytes = 0;
      }
      if (verbose) onChatter?.call('[daemon:err] $t');
    }
  }

  void _onExit(int code) {
    _exited = true;
    _failAllPending('flutter attach exited (code $code)');
    if (!_events.isClosed) unawaited(_events.close());
  }

  /// Handles one stdout line. Single-element JSON arrays are the pinned
  /// protocol shape; bare JSON objects and chatter are tolerated
  /// (feature-detect, ADR-0011 §2).
  void _handleLine(String raw) {
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

  void _handleEvent(DaemonEvent event) {
    final firstOfKind = !_seen.containsKey(event.event);
    _seen[event.event] = event;
    _appendEventRing(event);
    if (event.event == 'app.started') {
      _stopAfterStartBeforeStarted = false;
    }
    if (_isStopFatalBeforeStarted(event)) {
      _stopAfterStartBeforeStarted = true;
    }
    if (event.event == 'app.start' && firstOfKind) {
      _appStart?.complete();
      _appStart = null;
    }
    if (verbose) _chatter('[daemon] $event');
    if (!_events.isClosed) _events.add(event);
  }

  void _handleResponse(Map<Object?, Object?> item) {
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

  void _chatter(String line) {
    if (verbose) onChatter?.call(line);
  }

  // -- Outbound ---------------------------------------------------------------

  /// Waits (bounded) for the daemon's `app.start` event — commands are sent
  /// only after it (protocol fact pinned in H0). Throws [DaemonException]
  /// on timeout or daemon exit.
  Future<void> waitAppStart({
    Duration timeout = const Duration(seconds: 90),
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

  /// After [waitAppStart], wait for `app.started` or fail fast on `app.stop` /
  /// daemon exit (no full [timeout] wait once fatal machine events are seen).
  Future<AttachHandshakeFailure?> waitForAppStarted({
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (appStartedReceived) return null;
    final pre = precheckAttachHandshakeFailure();
    if (pre != null) return pre;
    final completer = Completer<AttachHandshakeFailure?>();
    late final StreamSubscription<DaemonEvent> sub;
    Timer? timer;
    void done(AttachHandshakeFailure? failure) {
      if (!completer.isCompleted) completer.complete(failure);
    }

    sub = events.listen((event) {
      if (event.event == 'app.started') {
        done(null);
        return;
      }
      if (_isStopFatalBeforeStarted(event)) {
        done(AttachHandshakeFailure.appStopBeforeStarted);
      }
    });

    timer = Timer(timeout, () {
      if (!appStartedReceived) {
        done(AttachHandshakeFailure.timedOut);
      } else {
        done(null);
      }
    });

    late final StreamSubscription<void> exitSub;
    exitSub = _transport.exitCode.then((_) {
      if (!appStartedReceived && !completer.isCompleted) {
        done(AttachHandshakeFailure.daemonExitedBeforeStarted);
      }
    }).asStream().listen((_) {});

    try {
      return await completer.future;
    } finally {
      timer.cancel();
      await sub.cancel();
      await exitSub.cancel();
    }
  }

  /// Sends [method] with [params], waiting for the matching response.
  /// Commands are gated behind `app.start` per the pinned protocol facts.
  Future<DaemonResponse> send(
    String method, {
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 60),
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
    required bool fullRestart,
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

  /// Bounded attach daemon shutdown: `daemon.shutdown`, then await process
  /// exit; kill remains the backstop when the RPC or exit stalls.
  Future<DaemonDisposeReport> disposeGracefully({
    DevSessionTeardownBudget? budget,
    Duration shutdownTimeout = const Duration(seconds: 6),
    Duration exitTimeout = const Duration(seconds: 6),
  }) async {
    var shutdownAttempted = false;
    var shutdownAcknowledged = false;
    var processExited = false;
    var killedAsBackstop = false;
    String? message;

    if (!_exited) {
      try {
        shutdownAttempted = true;
        if (appStartReceived) {
          final r = budget == null
              ? await shutdown().timeout(shutdownTimeout)
              : await budget.run(
                  shutdown,
                  cap: shutdownTimeout,
                );
          shutdownAcknowledged = r.ok;
          if (!r.ok) {
            message = r.errorText;
          }
        } else {
          try {
            _transport.writeLine(
              jsonEncode([
                {'id': _nextId++, 'method': 'daemon.shutdown'},
              ]),
            );
          } on Object catch (e) {
            message = e.toString();
          }
        }
      } on TimeoutException {
        message = 'daemon.shutdown timed out after ${shutdownTimeout.inSeconds}s';
      } on Object catch (e) {
        message = e.toString();
      }
      try {
        if (budget == null) {
          await exitCode.timeout(exitTimeout);
        } else {
          await budget.run(
            () => exitCode,
            cap: exitTimeout,
          );
        }
        processExited = _exited;
      } on TimeoutException {
        message ??=
            'attach process did not exit within ${exitTimeout.inSeconds}s';
      } on DevSessionTeardownBudgetExhausted {
        message ??= 'teardown budget exhausted before attach exit';
      } on Object catch (e) {
        message ??= e.toString();
      }
      if (!_exited) {
        killedAsBackstop = _transport.kill();
        try {
          await exitCode.timeout(const Duration(seconds: 2));
          processExited = _exited;
        } on Object {
          // Backstop kill sent; outcome reported via [killedAsBackstop].
        }
      } else {
        processExited = true;
      }
    } else {
      processExited = true;
    }
    for (final s in _subscriptions) {
      await s.cancel();
    }
    if (!_events.isClosed) await _events.close();
    return DaemonDisposeReport(
      shutdownAttempted: shutdownAttempted,
      shutdownAcknowledged: shutdownAcknowledged,
      processExited: processExited,
      killedAsBackstop: killedAsBackstop,
      message: message,
    );
  }

  /// Fire-and-forget shutdown + process kill (legacy backstop for callers
  /// that cannot await teardown).
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

  void _failAllPending(String why) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(DaemonException(why));
    }
    _pending.clear();
  }
}
