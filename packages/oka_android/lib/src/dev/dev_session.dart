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
/// * [DevFlow] — the outer loop: session → (native change with
///   `--rebuild-on-native`? build → reinstall → relaunch → re-attach) →
///   session again.
library;

import 'dart:async';
import 'dart:convert';

import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../android_artifacts.dart';
import '../build/toolchain.dart';
import 'adb_tool.dart';
import 'daemon_adapter.dart';
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

  /// Injectable [AdbTool] (tests point it at an injectable process
  /// runner; production resolves from [adbPath] → [toolchain]).
  final AdbTool? tool,
}) async {
  final adb =
      tool ??
      AdbTool(
        adbPath: adbPath ?? await (toolchain ?? ResolvedToolchain()).findAdb(),
      );
  final List<AdbDevice> devices;
  try {
    devices = await adb.devices();
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
    final attached = devices.isNotEmpty;
    return DevDeviceSelection.refused(
      '❌ No ready device${attached ? ' (${devices.length} attached but '
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

/// Resolves the session tool path via the toolchain policy; returns a
/// typed refusal (oka-branded fix) instead of throwing — the CLI prints it
/// verbatim (parse-and-delegate, ADR-0015).
Future<({String? path, String? refusal})> resolveDevToolPath(
  final ResolvedToolchain? toolchain,
) async {
  try {
    return (
      path: await (toolchain ?? ResolvedToolchain()).findAdb(),
      refusal: null,
    );
  } on ToolchainException {
    return (
      path: null,
      refusal:
          '❌ Platform tools not found — the dev session needs adb '
          'for install/launch and the attach child needs its directory on '
          'PATH.\n'
          '   fix: install platform-tools (`oka get android-sdk`).',
    );
  }
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

  /// Host-reachable VM service endpoint (`ws://127.0.0.1:<local>/<auth>`,
  /// via the pure [forwardedVmServiceUri] helper of the H2 adb layer).
  final String vmServiceUri;

  /// The local adb-forwarded port ([vmServiceLocalPort] artifact).
  final int vmServiceLocalPort;
}

/// Thrown when the device half of `oka dev` fails; the message is
/// oka-branded and actionable (step failures already are).
class DevLaunchException implements Exception {
  DevLaunchException(this.message);
  final String message;

  @override
  String toString() => message;
}

// -- VM-service URI artifact (machine-readable discovery) --------------------

/// Path of the live dev-session discovery file:
/// `<project>/.oka_cache/dev/vm.uri` — one line, the forwarded
/// `ws://127.0.0.1:<port>/<auth>/ws` endpoint. Verification/inspection
/// tools (e.g. `flutter_mcp_cli --vm-service-uri`) read this instead of
/// scraping the `oka dev --json` stream. Absent = no live session.
String vmUriFilePath(final String projectPath) =>
    p.join(projectPath, '.oka_cache', 'dev', 'vm.uri');

/// Writes the discovery file (best-effort: a failed write must never break
/// the dev session).
Future<void> writeVmUriFile(
  final String projectPath,
  final String vmServiceUri,
) async {
  try {
    final f = File(vmUriFilePath(projectPath));
    await f.parent.create(recursive: true);
    await f.writeAsString('$vmServiceUri\n', flush: true);
  } on FileSystemException {
    // best-effort — the session itself does not depend on the file.
  }
}

/// Removes the discovery file (session over → no live endpoint).
Future<void> clearVmUriFile(final String projectPath) async {
  try {
    await File(vmUriFilePath(projectPath)).delete();
  } on FileSystemException {
    // already gone — fine.
  }
}

/// Path of the live dev-session discovery file (spec v2 — the
/// toolkit-neutral Dart dev session contract):
/// `<project>/.flutter_mcp/runner-session.json` — the sibling of the
/// toolkit's own `.flutter_mcp/state.json` (overridable on the toolkit
/// side via its `--runner-session-file` flag). Written by the RUNNER (oka
/// is the first conforming runner) at each `session.ready` and deleted on
/// session exit. Readers reject unknown `schema` values; absent file = no
/// live delegable session. The `runner` field is display metadata only.
String runnerSessionFilePath(final String projectPath) =>
    p.join(projectPath, '.flutter_mcp', 'runner-session.json');

/// Writes the runner-session discovery file per spec v2 (best-effort,
/// same law as the vm.uri file: a failed write must never break the dev
/// session). `vmServiceUri` is the FORWARDED host-reachable endpoint
/// (same value the vm.uri file carries); `controlPort` is the loopback
/// delegation server's chosen port (ephemeral by default — only
/// discoverable here). Creating `.flutter_mcp/` never touches an existing
/// sibling `state.json`.
Future<void> writeRunnerSessionFile(
  final String projectPath, {
  required final String vmServiceUri,
  required final int controlPort,
  required final String deviceId,
  final int? processPid,
  final DateTime? startedAt,
}) async {
  try {
    final f = File(runnerSessionFilePath(projectPath));
    await f.parent.create(recursive: true);
    final map = <String, Object?>{
      'schema': 1,
      'runner': 'oka-dev',
      'vm_service_uri': vmServiceUri,
      'control_port': controlPort,
      'device_id': deviceId,
      'pid': processPid ?? pid,
      'started_at':
          (startedAt ?? DateTime.now().toUtc()).toIso8601String(),
    };
    await f.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(map)}\n',
      flush: true,
    );
  } on FileSystemException {
    // best-effort — the session itself does not depend on the file.
  }
}

/// Removes the runner-session discovery file (session over → no live
/// channel). Only the file is deleted — never the `.flutter_mcp/`
/// directory or any sibling file (e.g. the toolkit's `state.json`).
Future<void> clearRunnerSessionFile(final String projectPath) async {
  try {
    await File(runnerSessionFilePath(projectPath)).delete();
  } on FileSystemException {
    // already gone — fine.
  }
}

/// Typed view of `.flutter_mcp/runner-session.json` (see
/// [readRunnerSessionFile]).
class DevSessionDiscovery {
  const DevSessionDiscovery({
    required this.vmServiceUri,
    required this.controlPort,
    required this.deviceId,
    required this.pid,
    required this.startedAt,
  });

  /// The FORWARDED host-reachable VM service endpoint — pass it as the
  /// flutter MCP toolkit connection override `{mode: 'uri', uri: ...}`.
  final String vmServiceUri;

  /// Loopback delegation-channel port (no auth — localhost-only tool).
  final int controlPort;

  final String deviceId;
  final int pid;
  final DateTime startedAt;
}

/// Reads the session discovery file: `null` when absent (no live
/// session); [FormatException] when the file exists but is unreadable or
/// carries an unknown `schema` (readers reject unknown schema values).
DevSessionDiscovery? readRunnerSessionFile(final String projectPath) {
  final f = File(runnerSessionFilePath(projectPath));
  if (!f.existsSync()) return null;
  late final Map<String, Object?> json;
  try {
    json = (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
  } on FormatException catch (e) {
    throw FormatException(
      'Unreadable ${runnerSessionFilePath(projectPath)}: ${e.message}\n'
      '   fix: delete the stale file (or let the owning `oka dev` exit — '
      'it clears it) and re-run.',
    );
  }
  final schema = json['schema'];
  if (schema != 1) {
    throw FormatException(
      'Unsupported runner-session.json schema: $schema (supported: 1).\n'
      '   fix: re-run `oka dev` to rewrite the file with the current '
      'schema, or upgrade the reader.',
    );
  }
  final uri = json['vm_service_uri'];
  final port = json['control_port'];
  final device = json['device_id'];
  final pid = json['pid'];
  final startedAt = json['started_at'];
  if (uri is! String ||
      port is! int ||
      device is! String ||
      pid is! int ||
      startedAt is! String) {
    throw FormatException(
      'Incomplete ${runnerSessionFilePath(projectPath)} — all fields '
      '(schema, vm_service_uri, control_port, device_id, pid, '
      'started_at) are required.\n'
      '   fix: re-run `oka dev` to rewrite the file.',
    );
  }
  return DevSessionDiscovery(
    vmServiceUri: uri,
    controlPort: port,
    deviceId: device,
    pid: pid,
    startedAt: DateTime.parse(startedAt),
  );
}

/// Runs the device half of `oka dev` through the same validated [Pipeline]
/// as every other flow (ADR-0002): the [DeviceTarget] steps (resolve newest
/// APK → install → launch → logcat failure scan) followed by the H2
/// session steps (await VM service announcement → adb forward), consuming
/// the `vm_service_uri` / `vm_service_local_port` artifacts as-is.
Future<DevLaunchPrepared> prepareDevLaunch({
  required final String projectPath,
  final ResolvedToolchain? toolchain,

  /// Device serial — required on multi-device hosts (phone + emulator);
  /// threaded to every device step and the AdbTool VM-service operations.
  final String? deviceId,

  /// Injectable tool paths (tests / explicit config); null → [toolchain].
  /// Forwarded to the device steps and to the attach spawn (the flutter
  /// tool discovers devices through the platform-tools dir on PATH).
  final String? adbPath,
  final int waitSeconds = 3,
  final bool verbose = false,
}) async {
  final ctx = BuildContext(
    projectPath: projectPath,
    buildDir: p.join(projectPath, '.oka_cache', 'build', 'debug'),
    mode: BuildMode.debug,
    config: OkaConfig.empty,
    cacheDir: p.join(projectPath, '.oka_cache'),
    verbose: verbose,
  );
  // DeviceTarget machinery (ADR-0015) — install/launch/logscan are the
  // exact steps `oka run device` runs; no duplicated device logic.
  final steps = [
    ...DeviceTarget(
      waitSeconds: waitSeconds,
      deviceId: deviceId,
      adbPath: adbPath,
      toolchain: toolchain,
    ).compile(ctx),
    AwaitVmServiceStep(deviceId: deviceId, adbPath: adbPath, toolchain: toolchain),
    ForwardVmServiceStep(deviceId: deviceId, adbPath: adbPath, toolchain: toolchain),
  ];
  final pipeline = Pipeline(steps);
  final validationError = pipeline.validate();
  if (validationError != null) {
    throw DevLaunchException(validationError);
  }
  final state = PipelineState();
  final result = await pipeline.run(ctx, initialState: state);
  if (!result.ok) {
    throw DevLaunchException(result.error ?? 'device launch failed');
  }
  final vmUri = state[vmServiceUri.id] as String?;
  final localPort = state[vmServiceLocalPort.id] as int?;
  if (vmUri == null || localPort == null) {
    throw DevLaunchException(
      'device steps completed without the VM service artifacts '
      '(vm_service_uri=$vmUri, vm_service_local_port=$localPort)',
    );
  }
  // Rebuild the host-reachable endpoint from the forwarded port (pure H2
  // helper — the forward rewired host→loopback).
  final parsed = Uri.parse(vmUri);
  final info = VmServiceInfo(
    scheme: parsed.scheme,
    host: parsed.host,
    port: parsed.port,
    auth: parsed.path.replaceAll(RegExp(r'^/+|/+$'), ''),
    uri: vmUri,
  );
  final hostUri = forwardedVmServiceUri(info, localPort);
  await writeVmUriFile(projectPath, hostUri);
  return DevLaunchPrepared(
    apkPath: state[apkPath.id] as String? ?? '',
    vmServiceUri: hostUri,
    vmServiceLocalPort: localPort,
  );
}

// -- Control surface ---------------------------------------------------------

/// Session control commands. Sources: the human TTY keyboard loop
/// (`r`/`R`/`q`/`d` — see [devCommandFromKey]), the `--json` stdin line
/// protocol (`reload`/`restart`/`stop`/`detach`/`quit` — see
/// [devCommandFromLine]), and the `--watch` dispatcher (Dart change →
/// [DevControlCommand.reload]; native change → [DevControlCommand
/// .rebuildRouting]).
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
DevControlCommand? devCommandFromLine(final String line) =>
    switch (line.trim().toLowerCase()) {
      'reload' || 'r' => DevControlCommand.reload,
      'restart' => DevControlCommand.restart,
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

  /// The app stopped during a hot restart (`app.stop` mid-`app.restart`) —
  /// observed on some physical devices where attach-mode full restart lacks
  /// relaunch data. The flow relaunches (no rebuild) and re-attaches.
  relaunchRequested,
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
    this.onReady,
    this.onResult,
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

  /// Invoked once the session reaches `session.ready` (the discovery-file
  /// hook — `oka dev` writes `.flutter_mcp/runner-session.json` here).
  /// Purely additive: rendering is unchanged.
  final void Function()? onReady;

  /// Structured result hook for out-of-process delegation (the loopback
  /// control server): invoked from [_emit] for `reload.result`,
  /// `restart.result`, `restart.fallback`, and `app.stopped` with the
  /// event's data. Purely additive: rendering is unchanged.
  final void Function(String event, Map<String, Object?> data)? onResult;

  final _commandGate = Completer<DevSessionOutcome>();
  final _queued = <DevControlCommand>[];
  bool _draining = false;

  /// Runs the session to completion: wait `app.start` → `app.started` →
  /// serve control commands and render daemon events.
  Future<DevSessionOutcome> run() async {
    final eventSub = adapter.events.listen(_renderEvent);
    _emit('session.start', {
      'device': deviceId,
      'mode': session.buildMode,
      'target': session.targetFile,
    });

    // A daemon exit must end the session even with no commands flowing.
    final exitSub = adapter.exitCode
        .then((final code) {
          if (!_commandGate.isCompleted) {
            _commandGate.complete(DevSessionOutcome.daemonExited);
          }
        })
        .asStream()
        .listen((_) {});

    DevSessionOutcome outcome;
    try {
      try {
        await adapter.waitAppStart(timeout: startupTimeout);
      } on DaemonException catch (e) {
        write('❌ ${e.message}');
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
        return DevSessionOutcome.daemonExited;
      }
      _emit('session.ready', {
        'device': deviceId,
        if (adapter.wsUri != null) 'wsUri': adapter.wsUri,
      });

      outcome = await _serveCommands();
    } finally {
      await eventSub.cancel();
      await exitSub.cancel();
      adapter.dispose();
    }
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
      if (e.event == name && !completer.isCompleted) {
        completer.complete(true);
      }
    });
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(false);
    });
    final result = await completer.future;
    timer.cancel();
    await sub.cancel();
    return result;
  }

  Future<DevSessionOutcome> _serveCommands() async {
    StreamSubscription<DevControlCommand>? cmdSub;
    if (commands != null) {
      cmdSub = commands!.listen(
        _handleCommand,
        onDone: () {
          if (!_commandGate.isCompleted) {
            _commandGate.complete(DevSessionOutcome.daemonExited);
          }
        },
      );
    }
    final outcome = await _commandGate.future;
    await cmdSub?.cancel();

    // Tear-down per outcome. dispose() (in run()'s finally) sends
    // daemon.shutdown + kills the process as a backstop; quit first stops
    // the app (`app.stop`) so the device shows a clean exit; detach first
    // detaches (`app.detach`) — the app keeps running.
    if (outcome == DevSessionOutcome.quit) {
      await _trySend(adapter.stopApp);
    }
    if (outcome == DevSessionOutcome.detached) {
      await _trySend(adapter.detachApp);
      write('👋 Detaching — the app keeps running on $deviceId.');
    }
    return outcome;
  }

  void _handleCommand(final DevControlCommand c) {
    if (_commandGate.isCompleted) return;
    _queued.add(c);
    unawaited(_drainQueued());
  }

  Future<void> _drainQueued() async {
    if (_draining) return;
    _draining = true;
    while (_queued.isNotEmpty && !_commandGate.isCompleted) {
      final c = _queued.removeAt(0);
      await _applyCommand(c);
    }
    _draining = false;
  }

  Future<void> _applyCommand(final DevControlCommand c) async {
    switch (c) {
      case DevControlCommand.reload:
        final ok = await _dispatch(adapter.reload, label: 'Reload');
        _emit('reload.result', {'ok': ok});
      case DevControlCommand.restart:
        // Attach-mode full restart can stop the app instead of restarting
        // it (observed on physical devices: the flutter tool lacks relaunch
        // data when attached). Race the operation against `app.stop`; on a
        // mid-restart stop, hand control back to [DevFlow] to relaunch (no
        // rebuild) and re-attach.
        final stopped = Completer<void>();
        late final StreamSubscription<DaemonEvent> stopSub;
        stopSub = adapter.events.listen((final e) {
          if (e.event == 'app.stop' && !stopped.isCompleted) {
            stopped.complete();
          }
        });
        final opFuture = _dispatch(adapter.restart, label: 'Hot restart');
        final winner = await Future.any<bool?>([
          opFuture,
          stopped.future.then((_) => false),
        ]);
        await stopSub.cancel();
        if (winner == null || !winner) {
          write(
            '⚠️  The app stopped during hot restart (attach-mode limitation '
            'on this device) — falling back to relaunch + re-attach…',
          );
          _emit('restart.fallback', {});
          if (!_commandGate.isCompleted) {
            _commandGate.complete(DevSessionOutcome.relaunchRequested);
          }
          return;
        }
        _emit('restart.result', {'ok': winner});
      case DevControlCommand.stopApp:
        await _trySend(adapter.stopApp);
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

  /// Runs a daemon operation and renders the response; returns success.
  /// Reload failures and errors map to oka-branded messages an agent can
  /// act on from the message alone (H3 checklist). The operation goes
  /// through the adapter's typed methods (never a raw method string) —
  /// the adapter owns the wire details.
  Future<bool> _dispatch(
    final Future<DaemonResponse> Function() operation, {
    required final String label,
  }) async {
    write('🔁 $label…');
    try {
      final r = await operation();
      // A fallback (e.g. app stopped mid-restart) may have ended the session
      // while this operation was in flight — late writes are noise.
      if (_commandGate.isCompleted) return false;
      if (r.ok) {
        write('✅ $label complete.');
        return true;
      }
      write(
        '❌ $label failed: ${r.errorText}\n'
        '   fix: resolve the error above (most often a Dart compile error — '
        'check the edited file), then retry.',
      );
      return false;
    } on DaemonException catch (e) {
      if (_commandGate.isCompleted) return false;
      write(
        '❌ $label failed: ${e.message}\n'
        '   fix: if the daemon is gone, re-run `oka dev` '
        '(and `oka run device` first if the app is not running).',
      );
      return false;
    }
  }

  Future<void> _trySend(final Future<DaemonResponse> Function() send) async {
    try {
      await send().timeout(const Duration(seconds: 10));
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
        write('✅ App started.');
      case 'app.debugPort' || 'app.devTools' || 'app.dtd' || 'daemon.connected':
        if (verbose) write('[daemon] ${e.event}: ${e.params}');
      case 'app.reloadRecommended':
        final reason =
            e.field('reason')?.toString() ??
            'files changed outside the session';
        write(
          '💡 flutter_tools recommends a reload ($reason).\n'
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
    // Additive hooks (delegation channel) — never affect rendering.
    switch (event) {
      case 'session.ready':
        onReady?.call();
      case 'reload.result' ||
          'restart.result' ||
          'restart.fallback' ||
          'app.stopped':
        onResult?.call(event, data);
    }
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
        write('✅ Connected. Session commands ready.');
      case 'reload.result' || 'restart.result' || 'app.stopped':
      case 'rebuild.required':
        break; // dispatch / rebuild routing already rendered
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
  DevFlow({required this.prepare, required this.runBuild});

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
        case DevSessionOutcome.relaunchRequested:
          // Relaunch + re-attach only — no build. `prepare` reinstalls the
          // same APK (idempotent) and re-attaches with a fresh VM service.
          stderr.writeln('↩️  Relaunching and re-attaching…');
      }
    }
  }
}
