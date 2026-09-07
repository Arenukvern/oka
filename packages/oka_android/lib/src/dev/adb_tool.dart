/// Device-layer adb tool (ADR-0011 H2): command construction, output
/// parsers, and failure classification for the interactions `oka dev`
/// needs — device listing, install, launch, logcat, forward.
///
/// Split, per the H2 checklist contract:
///
/// * **Pure command construction + parsers** ([adbDevicesArgs],
///   [adbInstallArgs], [adbLaunchArgs], [adbForwardArgs],
///   [parseAdbDevices], [parseVmServiceUri], [parseForwardPort],
///   [classifyAdbFailure]) — unit-tested against recorded fixture output,
///   no binary needed.
/// * **[AdbTool]** — thin executor over an injectable adb path and process
///   runner; tests point it at scripted fake binaries (the
///   `adr0015_device_target_test` pattern).
/// * **Pipeline steps** ([AwaitVmServiceStep], [ForwardVmServiceStep]) —
///   compose the tool into the validated step chain (artifact contract
///   checked before any tool runs, per ADR-0002).
///
/// Human-readable failures: every adb failure goes through
/// [classifyAdbFailure] so "device unauthorized" / `INSTALL_FAILED_*` /
/// missing platform-tools name the oka-style next step instead of dumping
/// raw adb output.
library;

import 'dart:async';
import 'dart:io';

import 'package:oka_core/oka_core.dart';

import '../android_artifacts.dart';
import '../android_state.dart';
import '../build/toolchain.dart';

// -- Pure command construction ---------------------------------------------

/// `adb devices -l` (long listing: id, state, model).
List<String> adbDevicesArgs() => ['devices', '-l'];

/// `adb install -r <apk>` (reinstall, keep data).
List<String> adbInstallArgs(final String apk) => ['install', '-r', apk];

/// `adb shell am start -n <package>/<activity>`.
List<String> adbLaunchArgs(final String packageName, final String activity) =>
    ['shell', 'am', 'start', '-n', '$packageName/$activity'];

/// `adb forward tcp:<hostPort> tcp:<devicePort>`; [hostPort] 0 = adb picks
/// a free local port (printed on stdout).
List<String> adbForwardArgs({
  required final int devicePort,
  final int hostPort = 0,
}) =>
    ['forward', 'tcp:$hostPort', 'tcp:$devicePort'];

/// `adb logcat -d` (dump the current buffer — bounded scrape, no stream).
List<String> adbLogcatDumpArgs() => ['logcat', '-d'];

/// `adb logcat -c` (clear buffer before launch, per [LaunchAppStep]).
List<String> adbLogcatClearArgs() => ['logcat', '-c'];

// -- Pure parsers -----------------------------------------------------------

/// One entry of `adb devices [-l]` output.
class AdbDevice {
  const AdbDevice({required this.id, required this.state, this.model = ''});

  /// Serial / emulator-5554 / ip:port.
  final String id;

  /// `device`, `offline`, `unauthorized`, …
  final String state;

  /// From `-l` output (`model:Pixel_5`); empty for plain listing.
  final String model;

  bool get ready => state == 'device';

  @override
  String toString() =>
      model.isEmpty ? '$id ($state)' : '$id ($state, $model)';
}

/// Parses `adb devices -l` output into [AdbDevice]s. Tolerates the header
/// line, daemon-startup noise (`* daemon started successfully`), and empty
/// lines; returns an empty list when nothing is attached.
List<AdbDevice> parseAdbDevices(final String output) {
  final devices = <AdbDevice>[];
  for (final raw in output.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('List of devices')) continue;
    if (line.startsWith('*')) continue; // daemon/protocol noise
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    // A device line starts with the id followed by a state token; `-l` adds
    // key:value properties (usb:, product:, model:, device:, transport_id:).
    final id = parts[0];
    final state = parts[1];
    if (state.contains(':')) continue; // not a state token
    var model = '';
    for (final prop in parts.skip(2)) {
      if (prop.startsWith('model:')) model = prop.substring(6);
    }
    devices.add(AdbDevice(id: id, state: state, model: model));
  }
  return devices;
}

/// Parsed VM service announcement.
class VmServiceInfo {
  const VmServiceInfo({
    required this.scheme,
    required this.host,
    required this.port,
    required this.auth,
    required this.uri,
  });

  final String scheme;
  final String host;
  final int port;

  /// Auth code path segment (`/AUTHCODE=/` style); no leading slash.
  final String auth;
  final String uri;

  /// Full ws URI for the VM service (ws + auth path), ready for a client.
  String get wsUri => uri.replaceFirst('http://', 'ws://');
}

/// Scrapes the newest `Dart VM Service listening on <uri>` announcement from
/// a logcat dump. The *last* match wins (older runs may still be in the
/// buffer; `logcat -c` before launch is the primary guard).
///
/// The wording differs across Flutter versions (H0 probe finding): older
/// engines print `Dart VM Service listening on`, newer ones print
/// `The Dart VM service is listening on` — matched case-insensitively with
/// an optional `is`.
VmServiceInfo? parseVmServiceUri(final String log) {
  final re = RegExp(
    r'dart vm service (?:is )?listening on\s+(https?)://([^\s/:]+):(\d+)/(\S+)',
    caseSensitive: false,
  );
  VmServiceInfo? found;
  for (final m in re.allMatches(log)) {
    final auth = m.group(4)!.replaceAll(RegExp(r'/+$'), '');
    final uri = '${m.group(1)}://${m.group(2)}:${m.group(3)}/$auth';
    found = VmServiceInfo(
      scheme: m.group(1)!,
      host: m.group(2)!,
      port: int.parse(m.group(3)!),
      auth: auth,
      uri: uri,
    );
  }
  return found;
}

/// Parses the local port chosen by `adb forward tcp:0 tcp:<port>` (adb
/// prints the picked host port on stdout).
int? parseForwardPort(final String output) {
  final m = RegExp(r'(\d+)').firstMatch(output.trim());
  return m == null ? null : int.parse(m.group(1)!);
}

// -- Failure classification -------------------------------------------------

/// Classified adb failure with an oka-style next step.
class AdbFailure {
  const AdbFailure({
    required this.kind,
    required this.message,
    required this.fix,
  });

  /// Stable kind: `unauthorized`, `no-device`, `device-offline`,
  /// `signing-mismatch`, `install-failed`, `adb-missing`, `unknown`.
  final String kind;
  final String message;
  final String fix;

  @override
  String toString() => '$message\n   fix: $fix';
}

/// Maps raw adb output to a typed failure + oka-style remediation.
/// Best-effort: unknown outputs degrade to [AdbFailure.kind] = `unknown`
/// with the raw text — never a silent pass.
AdbFailure classifyAdbFailure(final String rawOutput) {
  final out = rawOutput.trim();
  final lower = out.toLowerCase();
  if (lower.contains('unauthorized') ||
      lower.contains('not authorized') ||
      lower.contains('insufficient permissions for device')) {
    return const AdbFailure(
      kind: 'unauthorized',
      message: 'Device unauthorized — USB debugging not accepted on this '
          'device (or adb lacks permission).',
      fix: 'Accept the "Allow USB debugging?" prompt on the device, or '
          '`adb kill-server && adb devices` to re-trigger it. On Linux, '
          'check the udev rules / plugdev group.',
    );
  }
  if (lower.contains('no devices') ||
      lower.contains("doesn't exist") ||
      lower.contains('device not found') ||
      lower.contains('no emulators')) {
    return const AdbFailure(
      kind: 'no-device',
      message: 'No device connected.',
      fix: 'Connect a device (USB debugging on) or start an emulator '
          '(`emulator -avd <name>`), then re-run.',
    );
  }
  if (lower.contains('offline') || lower.contains('closed')) {
    return const AdbFailure(
      kind: 'device-offline',
      message: 'Device is offline.',
      fix: 'Reconnect the device / wait for the emulator to finish booting, '
          'then `adb devices` to confirm it reports `device`.',
    );
  }
  if (lower.contains('install_failed_update_incompatible') ||
      lower.contains('incompatible')) {
    return const AdbFailure(
      kind: 'signing-mismatch',
      message: 'Signing-key mismatch: the device already has this app with a '
          'different key.',
      fix: 'Never uninstall an app with user data — build with the same key '
          'instead (android/key.properties / signing config).',
    );
  }
  if (lower.contains('install_failed_version_downgrade')) {
    return const AdbFailure(
      kind: 'install-failed',
      message: 'INSTALL_FAILED_VERSION_DOWNGRADE — the installed build has a '
          'higher versionCode.',
      fix: 'Bump the version (`oka.yaml`/config version or versionCode), or '
          'uninstall once (`adb uninstall <package>`) accepting the data '
          'loss.',
    );
  }
  if (lower.contains('install_failed')) {
    return AdbFailure(
      kind: 'install-failed',
      message: 'Install failed: $out',
      fix: 'See the INSTALL_FAILED_* code above — '
          'https://developer.android.com/tools/adb#installationerrors',
    );
  }
  if (lower.contains('adb: no adb') ||
      lower.contains('command not found') ||
      lower.contains('no such file')) {
    return const AdbFailure(
      kind: 'adb-missing',
      message: 'adb binary not found.',
      fix: 'Install platform-tools (`oka get android-sdk` or '
          '`sdkmanager "platform-tools"`).',
    );
  }
  return AdbFailure(
    kind: 'unknown',
    message: 'adb failed:\n$out',
    fix: 'Run `adb devices -l` and `oka doctor` to inspect the environment.',
  );
}

// -- Tool (injectable executor) ---------------------------------------------

/// Thin adb executor. All argv goes through the pure constructors above;
/// every failure is classified via [classifyAdbFailure]. Injectable adb
/// path + process runner for scripted-fake tests.
class AdbTool {
  AdbTool({
    required this.adbPath,
    final Future<ProcessResult> Function(String, List<String>)? runProcess,
  }) : _runProcess = runProcess ?? _defaultRun;

  static Future<ProcessResult> _defaultRun(
    final String exe,
    final List<String> args,
  ) =>
      Process.run(exe, args);

  final String adbPath;
  final Future<ProcessResult> Function(String, List<String>) _runProcess;

  Never _fail(final String operation, final ProcessResult r) {
    final f = classifyAdbFailure('${r.stdout}${r.stderr}');
    throw AdbToolException('adb $operation failed — ${f.message}', f);
  }

  /// Lists devices (long form). Returns every entry; callers filter on
  /// [AdbDevice.ready] / decide the zero-or-multiple-devices error.
  Future<List<AdbDevice>> devices() async {
    final r = await _runProcess(adbPath, adbDevicesArgs());
    if (r.exitCode != 0) _fail('devices', r);
    return parseAdbDevices(r.stdout as String);
  }

  /// `adb install -r`. Throws [AdbToolException] with the classified fix on
  /// failure (adb exits non-zero OR prints `Failure` while exiting 0).
  Future<void> install(final String apk) async {
    final r = await _runProcess(adbPath, adbInstallArgs(apk));
    final out = '${r.stdout}${r.stderr}';
    if (r.exitCode != 0 || out.contains('Failure')) _fail('install', r);
  }

  /// `adb shell am start -n <package>/<activity>`.
  Future<void> launch(final String packageName, final String activity) async {
    final r = await _runProcess(
      adbPath,
      adbLaunchArgs(packageName, activity),
    );
    if (r.exitCode != 0) _fail('am start', r);
  }

  /// Clears the logcat buffer (`logcat -c`) before a launch.
  Future<void> clearLogcat() async {
    final r = await _runProcess(adbPath, adbLogcatClearArgs());
    if (r.exitCode != 0) _fail('logcat -c', r);
  }

  /// Dumps the current logcat buffer (`logcat -d`).
  Future<String> logcatDump() async {
    final r = await _runProcess(adbPath, adbLogcatDumpArgs());
    if (r.exitCode != 0) _fail('logcat -d', r);
    return r.stdout as String;
  }

  /// `adb forward tcp:<hostPort> tcp:<devicePort>`; with [hostPort] 0,
  /// returns the local port adb picked (parsed from stdout).
  Future<int> forwardTcp({
    required final int devicePort,
    final int hostPort = 0,
  }) async {
    final r = await _runProcess(
      adbPath,
      adbForwardArgs(devicePort: devicePort, hostPort: hostPort),
    );
    if (r.exitCode != 0) _fail('forward', r);
    if (hostPort != 0) return hostPort;
    final port = parseForwardPort(r.stdout as String);
    if (port == null) {
      throw AdbToolException(
        'adb forward did not report the chosen local port '
        '(expected a number, got: ${r.stdout})',
        classifyAdbFailure('${r.stdout}${r.stderr}'),
      );
    }
    return port;
  }

  /// Bounded poll for the VM service announcement: dumps logcat every
  /// [pollInterval] until [parseVmServiceUri] matches or [timeout] passes.
  /// Returns null on timeout (caller decides the oka-branded failure).
  Future<VmServiceInfo?> awaitVmServiceUri({
    final Duration timeout = const Duration(seconds: 60),
    final Duration pollInterval = const Duration(milliseconds: 500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        final uri = parseVmServiceUri(await logcatDump());
        if (uri != null) return uri;
      } on AdbToolException {
        // Device may briefly drop the connection mid-boot; keep polling
        // until the deadline — the timeout path reports the failure.
      }
      if (DateTime.now().isAfter(deadline)) return null;
      await Future<void>.delayed(pollInterval);
    }
  }
}

/// Thrown by [AdbTool] on any classified failure.
class AdbToolException implements Exception {
  AdbToolException(this.message, this.failure);
  final String message;
  final AdbFailure failure;

  @override
  String toString() => '$message\n   fix: ${failure.fix}';
}

// -- Pipeline steps ---------------------------------------------------------

/// Resolves adb (injectable path → toolchain policy) for the VM-service
/// steps. Shared failure shape: missing adb is a failure naming the fix.
Future<String> resolveAdbForSteps(
  final PipelineState state, {
  final String? adbPath,
  final ResolvedToolchain? toolchain,
}) async {
  if (adbPath != null) return adbPath;
  return (toolchain ?? state.resolvedToolchain ?? ResolvedToolchain())
      .findAdb();
}

/// Waits (bounded) for the `Dart VM Service listening on …` announcement in
/// the device log after a debug launch, and provides [vmServiceUri]
/// (ADR-0011 H2). Requires `logcat -c` to have run before the launch so a
/// stale announcement from a previous run cannot match.
class AwaitVmServiceStep extends BuildStep {
  AwaitVmServiceStep({
    this.adbPath,
    this.toolchain,
    this.timeout = const Duration(seconds: 60),
    this.pollInterval = const Duration(milliseconds: 500),
  });

  /// Injectable adb path (tests / explicit config); null → toolchain.
  final String? adbPath;

  /// Null → [PipelineState.resolvedToolchain] → default policy.
  final ResolvedToolchain? toolchain;

  /// How long to wait for the announcement before failing.
  final Duration timeout;
  final Duration pollInterval;

  @override
  String get name => 'await-vm-service';

  @override
  Set<Artifact<Object>> get provides => {vmServiceUri};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final String adb;
    try {
      adb = await resolveAdbForSteps(state, adbPath: adbPath, toolchain: toolchain);
    } on ToolchainException {
      return StepResult.failure(
        'adb not found — install platform-tools (oka get android-sdk)',
      );
    }
    final tool = AdbTool(adbPath: adb);
    print('🔎 Waiting for the Dart VM service announcement (logcat)...');
    final info = await tool.awaitVmServiceUri(
      timeout: timeout,
      pollInterval: pollInterval,
    );
    if (info == null) {
      return StepResult.failure(
        'No "Dart VM Service listening on" announcement within '
        '${timeout.inSeconds}s. Is this a debug (JIT) build? '
        'Profile/release builds never expose a VM service.',
      );
    }
    print('🔌 VM service: ${info.uri}');
    state[vmServiceUri.id] = info.uri;
    return StepResult.success({vmServiceUri.id: info.uri});
  }
}

/// Forwards a local TCP port to the VM service port (adb forward tcp:0
/// tcp:DEVICE_PORT — adb picks a free local port) and provides
/// [vmServiceLocalPort] (ADR-0011 H2). Requires [vmServiceUri].
class ForwardVmServiceStep extends BuildStep {
  ForwardVmServiceStep({this.adbPath, this.toolchain});

  /// Injectable adb path (tests / explicit config); null → toolchain.
  final String? adbPath;

  /// Null → [PipelineState.resolvedToolchain] → default policy.
  final ResolvedToolchain? toolchain;

  @override
  String get name => 'forward-vm-service';

  @override
  Set<Artifact<Object>> get requires => {vmServiceUri};

  @override
  Set<Artifact<Object>> get provides => {vmServiceLocalPort};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final String adb;
    try {
      adb = await resolveAdbForSteps(state, adbPath: adbPath, toolchain: toolchain);
    } on ToolchainException {
      return StepResult.failure(
        'adb not found — install platform-tools (oka get android-sdk)',
      );
    }
    final uri = state[vmServiceUri.id]! as String;
    final devicePort = Uri.parse(uri).port;
    final tool = AdbTool(adbPath: adb);
    final int localPort;
    try {
      localPort = await tool.forwardTcp(devicePort: devicePort);
    } on AdbToolException catch (e) {
      return StepResult.failure(e.toString());
    }
    print('↔️  Forwarded localhost:$localPort → device:$devicePort');
    state[vmServiceLocalPort.id] = localPort;
    return StepResult.success({vmServiceLocalPort.id: localPort});
  }
}

/// Rebuilds the host-reachable VM service endpoint after
/// [ForwardVmServiceStep]: same scheme/auth path, host loopback, forwarded
/// local port. Pure, exported for tests.
String forwardedVmServiceUri(
  final VmServiceInfo info,
  final int localPort,
) =>
    '${info.scheme == 'https' ? 'wss' : 'ws'}://127.0.0.1:$localPort/'
    '${info.auth}';
