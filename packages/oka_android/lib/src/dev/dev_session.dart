/// `oka dev` session layer (ADR-0011 H3): device selection and the daemon
/// session loop — the CLI (`lib/src/cli/dev_command.dart`) stays
/// parse-and-delegate; every bit of session logic lives here.
///
/// Composition:
///
/// * [selectDevDevice] — `-d <id>` selection over `AdbTool.devices()`;
///   zero/multiple ready devices refuse with an oka-branded error; failures
///   map through `classifyAdbFailure`.
/// * [prepareDevLaunch] — reuses the DeviceTarget machinery (ADR-0015
///   device steps: resolve APK → install → launch → logscan) and appends
///   the H2 session steps (await VM service → forward), consuming the
///   `vm_service_uri` / `vm_service_local_port` artifacts as-is. No adb
///   logic is duplicated anywhere.
/// * [DevSession] — one attach session over [FlutterDaemonAdapter]:
///   renders daemon events for humans (`r`/`R`/`q`/`d` control) or emits a
///   structured JSON event stream for agents (`--json`; control lines
///   `reload` / `restart` / `stop` / `detach` / `quit` on stdin — the one
///   explicit interactive surface, never a build path).
/// * [DevFlow] — the outer loop: session → (watch native change and
///   `--rebuild-on-native`? rebuild → reinstall → relaunch → re-attach) →
///   session again.
library;

import 'dart:async';
import 'dart:convert';

import 'package:oka_core/oka_core.dart';

import 'adb_tool.dart';
import 'daemon_adapter.dart';
import 'device_steps.dart';
import 'device_target.dart';
import 'run_session.dart';

// -- Device selection -------------------------------------------------------

/// Result of [selectDevDevice]: exactly one ready device, or a refusal.
class DevDeviceSelection {
  const DevDeviceSelection._(this.device) : refusal = null;

  const DevDeviceSelection.refused(this.refusal) : device = null;

  final AdbDevice? device;
  final String? refusal;

  bool get ok => refusal == null;
}

/// Selects the device for the session (ADR-0011 H3):
///
/// * `-d <id>` must match an attached device (any state — the ready check
///   gives the precise failure via `classifyAdbFailure`).
/// * no `-d`: exactly one ready device is auto-selected; zero devices →
///   refusal naming the fix; multiple → refusal listing them.
/// * adb itself fails → classified refusal.
Future<DevDeviceSelection> selectDevDevice({
  final String? deviceId,
  final String? adbPath,
  final ResolvedToolchain? toolchain,
}) async {
  final tool = AdbTool(
    adbPath: adbPath ?? await (toolchain ?? ResolvedToolchain()).findAdb(),
  );
  final List<AdbDevice> devices;
  try {
    devices = await tool.devices();
  } on AdbToolException catch (e) {
    return DevDeviceSelection.refused('❌ Device listing failed.\n   $e');
  }
  if (deviceId != null && deviceId.trim().isNotEmpty) {
    final id = deviceId.trim();
    final match = devices.where((final d) => d.id == id).toList();
    if (match.isEmpty) {
      return DevDeviceSelection.refused(
        '❌ No device with id "$id" attached.\n'
        '   Attached: ${devices.isEmpty ? '(none)' : devices.join(', ')}\n'
        '   fix: run `adb devices -l` (or `oka doctor`) to list ids.',
      );
    }
    final d = match.single;
    if (!d.ready) {
      final f = classifyAdbFailure('device is ${d.state}');
      return DevDeviceSelection.refused(
        '❌ Device $d is not ready.\n   fix: ${f.fix}',
      );
    }
    return DevDeviceSelection._(d);
  }
  final ready = devices.where((final d) => d.ready).toList();
  if (ready.isEmpty) {
    final unauthorized = devices.isNotEmpty;
    return DevDeviceSelection.refused(
      '❌ No ready device${unauthorized ? ' (${devices.length} attached but '
          'not ready)' : ''}.\n'
      '   fix: connect a device with USB debugging, or start the emulator '
      '(`emulator -avd <name>`), then re-run.',
    );
  }
  if (ready.length > 1) {
    return DevDeviceSelection.refused(
      '❌ Multiple devices attached — pass `-d <device-id>`:\n'
      '${ready.map((final d) => '   - $d').join('\n')}',
    );
  }
  return DevDeviceSelection._(ready.single);
}

// -- Device steps (reuse DeviceTarget machinery) -----------------------------

/// Result of [prepareDevLaunch]: the device-side launch is done and the VM
/// service is reachable (H2 artifacts consumed as-is).
class DevLaunchPrepared {
  const DevLaunchPrepared({
    required this.apkPath,
    required this.vmServiceUri,
    required this.vmServiceLocalPort,
  });

  final String apkPath;

  /// Host-reachable VM service URI (`ws://127.0.0.1:<local>/<auth>`,
  /// from `forwardedVmServiceUri`).
  final String vmServiceUri;

  /// The local adb-forwarded port ([vmServiceLocalPort] artifact).
  final int vmServiceLocalPort;
}

/// Runs the device half of `oka dev` through the same validated [Pipeline]
/// as every other flow (ADR-0002): the [DeviceTarget] steps (resolve newest
/// APK → install → launch → logcat failure scan) followed by the H2
/// session steps (await VM service announcement → adb forward), consuming
/// the `vm_service_uri` / `vm_service_local_port` artifacts as-is.
Future<DevLaunchPrepared> prepareDevLaunch({
  required final String projectPath,
  final ResolvedToolchain? toolchain,
  final int waitSeconds = 3,
  final bool verbose = false,
}) async {
  final buildDir = p.join(projectPath, '.oka_cache', 'build', 'debug');
  final ctx = BuildContext(
    projectPath: projectPath,
    buildDir: buildDir,
    mode: BuildMode.debug,
    config: OkaConfig.empty,
    cacheDir: p.join(projectPath, '.oka_cache'),
    verbose: verbose,
  );
  // DeviceTarget machinery (ADR-0015) — install/launch/logscan are the
  // exact steps `oka run device` runs; no duplicated device logic.
  final steps = [
    ...const DeviceTarget(waitSeconds: waitSeconds).compile(ctx),
    AwaitVmServiceStep(toolchain: toolchain),
    ForwardVmServiceStep(toolchain: toolchain),
  ];
  final pipeline = Pipeline(steps);
  final error = pipeline.validate();
  if (error != null) {
    throw DevLaunchException(error);
  }
  final result = await pipeline.run(ctx);
  if (!result.ok) {
    throw DevLaunchException(result.error ?? 'device launch failed');
  }
  final uri = ctx.dartDefines.isEmpty ? null : null; // no-op; see below
  final state = result.data;
  final vmUri = state['vm_service_uri'] as String?;
  final localPort = state['vm_service_local_port'] as int?;
  if (vmUri == null || localPort == null) {
    throw DevLaunchException(
      'device steps completed without VM service artifacts '
      '(vm_service_uri=$vmUri, vm_service_local_port=$localPort)',
    );
  }
  // Rebuild the host-reachable endpoint from the forwarded port (pure
  // helper from the H2 adb layer).
  final info = parseVmServiceUri('Dart VM service listening on $vmUri')!;
  final hostUri = forwardedVmServiceUri(info, localPort);
  return DevLaunchPrepared(
    apkPath: state['apk_path'] as String? ?? '',
    vmServiceUri: uri ?? hostUri,
    vmServiceLocalPort: localPort,
  );
}

/// Thrown when the device half of `oka dev` fails; the message is
/// oka-branded and actionable (step failures already are).
class DevLaunchException implements Exception {
  DevLaunchException(this.message);
  final String message;

  @override
  String toString() => message;
}

// -- Control surface ---------------------------------------------------------

/// Session control commands. Sources: the human TTY keyboard loop
/// (`r`/`R`/`q`/`d` — see [devCommandFromKey]), the `--json` stdin line
/// protocol (`reload`/`restart`/`stop`/`detach`/`quit` — see
/// [devCommandFromLine]), and the `--watch` dispatcher (Dart change →
/// [DevControlCommand.reload]; native change → [rebuildRouting]).
enum DevControlCommand {
  /// Hot reload (Dart-only changes).
  reload,

  /// Hot restart (full kernel recompile + restart; state loss).
  restart,

  /// Stop the running app but keep the daemon.
  stopApp,

  /// Detach: leave the app running, shut the daemon down.
  detach,

  /// Quit: stop the app, shut the daemon down, exit the session.
  quit,

  /// A watched change requires a full rebuild (native/res/manifest/…).
  /// The session ends with [DevSessionOutcome.rebuildRequested] when
  /// `--rebuild-on-native` is on; otherwise it prints the exact command.
  rebuildRouting,
}

/// Maps the human TTY keyboard loop to commands (`r` reload, `R` hot
/// restart, `q` quit, `d` detach). Returns null for unrecognized keys.
DevControlCommand? devCommandFromKey(final String key) => switch (key) {
      'r' => DevControlCommand.reload,
      'R' => DevControlCommand.restart,
      'q' => DevControlCommand.quit,
      'd' => DevControlCommand.detach,
      _ => null,
    };

/// Maps a `--json` stdin control line to a command. Returns null for
/// blank/unknown lines (unknown lines are answered with the key list).
DevControlCommand? devCommandFromLine(final String line) => switch (
      line.trim().toLowerCase()
    ) {
      'reload' || 'r' => DevControlCommand.reload,
      'restart' || 'r+' => DevControlCommand.restart,
      'stop' => DevControlCommand.stopApp,
      'detach' => DevControlCommand.detach,
      'quit' || 'exit' => DevControlCommand.quit,
      _ => null,
    };

/// How a [DevSession] ended.
enum DevSessionOutcome {
  /// User quit (`q`) — app stopped, daemon shut down.
  quit,

  /// User detached (`d`) — app left running, daemon shut down.
  detached,

  /// The daemon process exited on its own.
  daemonExited,

  /// A watched change requires a full rebuild (only with
  /// `--rebuild-on-native`); the flow rebuilds and re-attaches.
  rebuildRequested,
}

// -- Session -----------------------------------------------------------------

/// One `flutter attach --machine` session (ADR-0011 H3).
///
/// All rendering goes through [write] — the CLI passes `print`-like sinks;
/// tests capture lines. JSON mode emits one structured object per line
/// (`pipeline_events.dart`-style envelope): `{"scope": "dev", "event": ...,
/// "params": {...}, "timestamp": ...}`.
class DevSession {
  DevSession({
    required this.adapter,
    required this.session,
    required this.deviceId,
    required this.json,
    required this.write,
    this.commands,
    this.verbose = false,
    this.rebuildOnNative = false,
    this.startupTimeout = const Duration(seconds: 90),
  });

  /// The spawned daemon adapter (real process or scripted fake).
  final FlutterDaemonAdapter adapter;

  /// The validated session manifest (H1).
  final RunSession session;

  /// Selected device id (echoed in status output).
  final String deviceId;

  /// `--json` agent stream (structured events on [write], no TUI).
  final bool json;

  /// Output sink for rendered lines / JSON events.
  final void Function(String line) write;

  /// Control-command source (keyboard / stdin lines / watch dispatcher).
  final Stream<DevControlCommand>? commands;

  final bool verbose;

  /// `--rebuild-on-native`: a native/res/manifest change ends the session
  /// with [DevSessionOutcome.rebuildRequested] instead of only printing
  /// the exact rebuild command.
  final bool rebuildOnNative;

  final Duration startupTimeout;

  Future<void>? _exitSubscriptionDone;

  /// Runs the session to completion: wait `app.start` → `app.started` →
  /// serve control commands and render daemon events.
  Future<DevSessionOutcome> run() async {
    final eventSub = adapter.events.listen(_renderEvent);
    _emit('session.start', {
      'device': deviceId,
      'mode': session.buildMode,
      'target': session.targetFile,
    });

    try {
      await adapter.waitAppStart(timeout: startupTimeout);
    } on DaemonException catch (e) {
      write('❌ ${e.message}');
      adapter.dispose();
      return DevSessionOutcome.daemonExited;
    }

    // Wait for app.started (bounded) — attach syncs files first.
    final started = await _waitForEvent(
      'app.started',
      timeout: startupTimeout,
    );
    if (!started) {
      write(
        '❌ flutter attach did not reach app.started within '
        '${startupTimeout.inSeconds}s. Is the app running on $deviceId?\n'
        '   fix: `oka run device` first (installs + launches the '
        'oka-built debug APK), then re-run `oka dev`.',
      );
      adapter.dispose();
      return DevSessionOutcome.daemonExited;
    }
    _emit('session.ready', {
      'device': deviceId,
      if (adapter.wsUri != null) 'wsUri': adapter.wsUri,
    });

    final outcome = await _serveCommands();
    await eventSub.cancel();
    return outcome;
  }

  Future<bool> _waitForEvent(
    final String name, {
    required final Duration timeout,
  }) async {
    if (adapter.lastEvent(name) != null) return true;
    final completer = Completer<bool>();
    late final StreamSubscription<DaemonEvent> sub;
    sub = adapter.events.listen((final e) {
      if (e.event != name || completer.isCompleted) return;
      completer.complete(true);
    });
    adapter.exitCodeTimeoutHack(timeout, () {
      if (!completer.isCompleted) completer.complete(false);
    });
    final result = await completer.future;
    await sub.cancel();
    return result;
  }

  Future<DevSessionOutcome> _serveCommands() async {
    final exitWatch = adapter.transportExitCode.then((final code) {
      // Daemon exited on its own (crash, or killed externally).
      if (!_commandGate.isCompleted) _commandGate.complete(
          DevSessionOutcome.daemonExited,
        );
    });
    _exitSubscriptionDone = exitWatch;

    StreamSubscription<DevControlCommand>? cmdSub;
    if (commands != null) {
      cmdSub = commands!.listen(
        (final c) => _handleCommand(c),
        onDone: () {
          if (!_commandGate.isCompleted) {
            _commandGate.complete(DevSessionOutcome.daemonExited);
          }
        },
      );
    }
    final outcome = await _commandGate.future;
    await cmdSub?.cancel();

    // Tear-down per outcome.
    if (outcome == DevSessionOutcome.quit) {
      await _trySend('app.stop', label: 'stop');
      adapter.dispose();
    } else if (outcome == DevSessionOutcome.detached) {
      write('👋 Detaching — the app keeps running on $deviceId.');
      adapter.dispose();
    }
    return outcome;
  }

  final _commandGate = Completer<DevSessionOutcome>();

  Future<void> get transportExitCode => adapter.transport.exitCode;

  bool _handling = false;
  final _queued = <DevControlCommand>[];

  void _handleCommand(final DevControlCommand c) {
    if (_commandGate.isCompleted) return;
    _queued.add(c);
    _drainQueued();
  }

  Future<void> _drainQueued() async {
    if (_handling) return;
    _handling = true;
    while (_queued.isNotEmpty && !_commandGate.isCompleted) {
      final c = _queued.removeAt(0);
      await _applyCommand(c);
    }
    _handling = false;
  }

  Future<void> _applyCommand(final DevControlCommand c) async {
    switch (c) {
      case DevControlCommand.reload:
        final r = await _dispatch('app.reload', label: 'reload');
        _emit('reload.result', {'ok': r});
      case DevControlCommand.restart:
        final r = await _dispatch('app.restart', label: 'hot restart');
        _emit('restart.result', {'ok': r});
      case DevControlCommand.stopApp:
        await _trySend('app.stop', label: 'stop');
        _emit('app.stopped', {});
      case DevControlCommand.detach:
        if (!_commandGate.isCompleted) {
          _commandGate.complete(DevSessionOutcome.detached);
        }
      case DevControlCommand.quit:
        if (!_commandGate.isCompleted) {
          _commandGate.complete(DevSessionOutcome.quit);
        }
      case DevControlCommand.rebuildRouting:
        if (rebuildOnNative) {
          write(
            '🔁 Watched change requires a full rebuild — stopping the '
            'session to rebuild.',
          );
          if (!_commandGate.isCompleted) {
            _commandGate.complete(DevSessionOutcome.rebuildRequested);
          }
        } else {
          write(fullRebuildMessage());
          _emit('rebuild.required', {'automatic': false});
        }
    }
  }

  /// Sends a command and renders the response; returns success. Reload
  /// failures and errors map to oka-branded messages an agent can act on
  /// from the message alone (H3 checklist).
  Future<bool> _dispatch(final String method, {required final String label}) async {
    write('🔁 $label…');
    try {
      final r = await adapter.send(method);
      if (r.ok) {
        write('✅ $label complete.');
        return true;
      }
      write(
        '❌ $label failed: ${r.errorText}\n'
        '   fix: resolve the error above (most often a Dart compile error — '
        'check the edited file), then retry `r`.',
      );
      return false;
    } on DaemonException catch (e) {
      write(
        '❌ $label failed: ${e.message}\n'
        '   fix: if the daemon is gone, re-run `oka dev` '
        '(and `oka run device` first if the app is not running).',
      );
      return false;
    }
  }

  Future<void> _trySend(
    final String method, {
    required final String label,
  }) async {
    try {
      await adapter.send(method, timeout: const Duration(seconds: 10));
    } on Exception {
      // Best-effort tear-down; dispose() kills the process as a backstop.
    }
  }

  void _renderEvent(final DaemonEvent e) {
    if (json) {
      _emitJson('daemon.${e.event}', e.params);
      return;
    }
    switch (e.event) {
      case 'app.progress':
        final finished = e.field('finished') == true;
        final message = e.field('message')?.toString() ?? e.event;
        if (!finished) write('⏳ $message');
      case 'app.started':
        // Rendered once at session.ready; the daemon may repeat it after
        // restart — acknowledge quietly.
        write('✅ App started.');
      case 'app.debugPort' || 'app.devTools' || 'app.dtd' || 'daemon.connected':
        if (verbose) write('[daemon] ${e.event}: ${e.params}');
      case 'app.reloadRecommended':
        write(
          '💡 flutter_tools recommends a reload (${e.field('reason') ?? '
          'files changed outside the session}).\n'
          '   → press `r` (or send `reload` with --json).',
        );
      case 'app.stop' || 'app.start':
        break; // session-level handling covers these
      default:
        // Unknown events are tolerated (feature-detect) and logged at -v
        // only (ADR-0011 §2).
        if (verbose) write('[daemon] ${e.event}: ${e.params}');
    }
  }

  void _emit(final String event, final Map<String, Object?> data) {
    if (json) {
      _emitJson(event, data);
      return;
    }
    switch (event) {
      case 'session.start':
        write(
          '🚀 oka dev — attach session on $deviceId '
          '(target=${session.targetFile}, mode=${session.buildMode})',
        );
        write(
          '   r hot reload · R hot restart (state loss) · '
          'q quit · d detach',
        );
      case 'session.ready':
        write('✅ Connected. Watching for session commands…');
      case 'reload.result' || 'restart.result':
        break; // dispatch already rendered
      case 'app.stopped' || 'rebuild.required':
        break;
    }
  }

  void _emitJson(final String event, final Map<String, Object?> data) {
    write(
      jsonEncode({
        'scope': 'dev',
        'event': event,
        'params': data,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }
}

/// The honest full-rebuild message (ADR-0011 §5: hot reload is Dart-only;
/// never suggest reload for native/res/manifest changes).
String fullRebuildMessage() =>
    '🧱 This change needs a full rebuild — hot reload is Dart-only '
    '(ADR-0011 §5).\n'
    '   fix: `oka build apk --debug` then `oka run device` '
    '(or re-run `oka dev`)\n'
    '   tip: `oka dev --watch --rebuild-on-native` does it automatically '
    '(build → reinstall → relaunch → re-attach).';

// -- Flow (outer loop: session → rebuild → session) ---------------------------

/// The outer `oka dev` flow: run one [DevSession]; when it ends with
/// [DevSessionOutcome.rebuildRequested], run the injected build (the exact
/// parity flags the session was validated against), then re-attach.
/// Quit/detach/daemon-exit end the flow.
class DevFlow {
  DevFlow({
    required this.prepare,
    required this.runBuild,
  });

  /// Prepares the device (install/launch/VM-service steps) and spawns one
  /// attach session. Called once per attach (again after each rebuild).
  final Future<DevSession> Function() prepare;

  /// Runs the full rebuild (`oka build apk --debug` with the session's
  /// parity flags). Returns false on failure (the flow stops).
  final Future<bool> Function() runBuild;

  /// Runs the flow; returns the process exit code.
  Future<int> run() async {
    while (true) {
      final DevSession session;
      try {
        session = await prepare();
      } on DevLaunchException catch (e) {
        stderr.writeln('❌ $e');
        return 1;
      }
      final outcome = await session.run();
      switch (outcome) {
        case DevSessionOutcome.quit:
          return 0;
        case DevSessionOutcome.detached:
          return 0;
        case DevSessionOutcome.daemonExited:
          return 1;
        case DevSessionOutcome.rebuildRequested:
          final ok = await runBuild();
          if (!ok) {
            stderr.writeln(
              '❌ Rebuild failed — fix the errors above and re-run '
              '`oka dev`.',
            );
            return 1;
          }
      }
    }
  }
}
