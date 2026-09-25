/// Platform liveness / identity / kill seam (ADR-0018 §1).
///
/// macOS, Linux, and Windows answer "is this pid alive, and is it *still
/// the same* process?" differently, so the seam is abstracted from day one.
/// The default implementation ([HostProcessLiveness]) covers macOS, Linux,
/// and Windows via built-in Windows PowerShell/CIM.
///
/// The seam exists because of **identity over pid** (ADR-0018 §1): every
/// kill verifies identity before signaling. Raw `kill <pid>` is forbidden —
/// pid recycling kills innocent processes. Identity is a process start-time
/// token ([identityToken]) or a semantic check at the call site (`adb emu
/// avd name` matches the lease, CDP `/json/version` answers on the leased
/// port).
library;

import 'dart:io';

/// Verdict of the identity-over-pid kill gate ([verifyKillIdentity]).
enum KillIdentity {
  /// The live process's start-time token matches the recorded one — safe
  /// to signal.
  verified,

  /// The pid is alive but its start-time token differs from the recorded
  /// one — the pid was recycled; **never signal**.
  recycled,

  /// Identity could not be established at all (dead pid, token
  /// unobtainable, platform seam unavailable) — report, never guess.
  unknown,
}

/// Identity-over-pid gate (ADR-0018 §1): decides whether it is safe to
/// signal [pid] given the start-time token [recordedToken] captured when
/// the process was spawned (stored in the lease under
/// [processLeasePidTokenKey]).
///
/// Returns [KillIdentity.verified] only when a token was recorded *and*
/// the live process's current token matches it. Every other outcome is
/// conservative: a recycled pid ([KillIdentity.recycled]) or an
/// unverifiable one ([KillIdentity.unknown]) must never be signaled.
///
/// The gate before ANY signal — the call sites (failure-path kills,
/// `stopLease`, the reconcile sweep) all funnel through it:
///
/// ```dart
/// final verdict = await verifyKillIdentity(liveness, pid, recordedToken);
/// switch (verdict) {
///   case KillIdentity.verified:
///     process.kill(); // SIGTERM — graceful-first
///   case KillIdentity.recycled:
///     // The pid belongs to someone else now. NEVER signal; drop the
///     // stale record instead.
///   case KillIdentity.unknown:
///     // Report-never-guess: keep the lease for the reconcile sweep.
/// }
/// ```
///
/// Pure with respect to the injected seam — scripted fakes in tests.
Future<KillIdentity> verifyKillIdentity(
  final ProcessLiveness liveness,
  final int pid,
  final String? recordedToken,
) async {
  if (pid <= 0) return KillIdentity.unknown;
  final String? current;
  try {
    current = await liveness.identityToken(pid);
  } on Object {
    // Platform seam unavailable (e.g. Windows L0 boundary): report,
    // never guess.
    return KillIdentity.unknown;
  }
  if (current == null || recordedToken == null) return KillIdentity.unknown;
  return current == recordedToken
      ? KillIdentity.verified
      : KillIdentity.recycled;
}

/// Platform liveness / identity / kill seam (ADR-0018 §1): the three
/// members every kind-specific lifecycle logic needs, abstracted from the
/// host OS.
abstract interface class ProcessLiveness {
  /// Whether a process with OS id [pid] is currently alive.
  Future<bool> isAlive(final int pid);

  /// An identity token that changes when the OS reuses [pid] for a
  /// different process — the process start time (or equivalent). Null when
  /// the process is not alive or the token is unobtainable.
  Future<String?> identityToken(final int pid);

  /// Stops [pid] after verifying its identity. Unix hosts try SIGTERM, wait
  /// up to [grace], then SIGKILL if still alive; Windows uses the process
  /// termination available through Dart's `Process.killPid`. Returns false
  /// when the process could not be safely stopped.
  Future<bool> kill(final int pid, {final Duration grace});
}

/// Default [ProcessLiveness]: `ps` / `kill -0` on macOS, `/proc/<pid>` on
/// Linux, and Windows PowerShell/CIM with machine and boot identity on
/// Windows.
final class HostProcessLiveness implements ProcessLiveness {
  /// Const constructor — stateless.
  const HostProcessLiveness();

  static const WindowsProcessLiveness _windows = WindowsProcessLiveness();

  @override
  Future<bool> isAlive(final int pid) async {
    if (pid <= 0) return false;
    if (Platform.isWindows) return _windows.isAlive(pid);
    if (Platform.isLinux) return Directory('/proc/$pid').existsSync();
    final result = await Process.run('kill', ['-0', '$pid']);
    return result.exitCode == 0;
  }

  @override
  Future<String?> identityToken(final int pid) async {
    if (pid <= 0) return null;
    if (Platform.isWindows) return _windows.identityToken(pid);
    if (Platform.isLinux) {
      final stat = await File('/proc/$pid/stat').readAsString();
      final bootId = (await File(
        '/proc/sys/kernel/random/boot_id',
      ).readAsString()).trim();
      return linuxProcessIdentityToken(bootId: bootId, stat: stat);
    }
    // macOS: `ps -o lstart= -p <pid>` — the process start time, stable for
    // the process's lifetime and different for every new process that
    // recycles the pid.
    final result = await Process.run('ps', ['-o', 'lstart=', '-p', '$pid']);
    final token = result.stdout.toString().trim();
    return token.isEmpty ? null : token;
  }

  @override
  Future<bool> kill(
    final int pid, {
    final Duration grace = const Duration(seconds: 3),
  }) async {
    if (pid <= 0) return false;
    if (Platform.isWindows) return _windows.kill(pid, grace: grace);
    final String? originalIdentity;
    try {
      originalIdentity = await identityToken(pid);
    } on Object {
      return false;
    }
    if (originalIdentity == null) return false;
    if (!Process.killPid(pid)) return false;
    await Future<void>.delayed(grace);
    if (await isAlive(pid)) {
      final String? currentIdentity;
      try {
        currentIdentity = await identityToken(pid);
      } on Object {
        return false;
      }
      if (currentIdentity == null || currentIdentity != originalIdentity) {
        return false;
      }
      // Force is the *last* rung of the ladder (ADR-0018 §1); a process
      // that ignored SIGTERM for [grace] gets SIGKILL.
      return Process.killPid(pid, ProcessSignal.sigkill);
    }
    return true;
  }
}

/// Injectable command seam used by [WindowsProcessLiveness] and its tests.
typedef ProcessCommandRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Windows process probe backed by inbox Windows PowerShell 5.1 and CIM.
///
/// A positive liveness result requires a valid process creation time, the
/// Windows machine GUID, and the OS boot time. If PowerShell, CIM, or any
/// identity component is unavailable, the probe throws (or returns null for
/// [identityToken]); it never infers liveness from a PID alone.
final class WindowsProcessLiveness implements ProcessLiveness {
  /// Uses `powershell.exe` unless a command runner is supplied for testing.
  const WindowsProcessLiveness({this.commandRunner});

  /// Optional test seam. Leave unset to invoke Windows PowerShell.
  final ProcessCommandRunner? commandRunner;

  Future<ProcessResult> _runCommand(
    final String executable,
    final List<String> arguments,
  ) =>
      commandRunner?.call(executable, arguments) ??
      Process.run(executable, arguments);

  Future<WindowsProcessSnapshot> _snapshot(final int pid) async {
    if (pid <= 0) throw ArgumentError.value(pid, 'pid', 'Must be positive');
    final result = await _runCommand('powershell.exe', [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      windowsProcessProbeScript(pid),
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        'powershell.exe',
        const ['<Windows process identity probe>'],
        result.stderr.toString(),
        result.exitCode,
      );
    }
    final snapshot = parseWindowsProcessProbeOutput(result.stdout.toString());
    if (snapshot == null) {
      throw const FormatException(
        'Windows process identity probe returned unverifiable output',
      );
    }
    return snapshot;
  }

  @override
  Future<bool> isAlive(final int pid) async {
    if (pid <= 0) return false;
    return (await _snapshot(pid)).isAlive;
  }

  @override
  Future<String?> identityToken(final int pid) async {
    if (pid <= 0) return null;
    return (await _snapshot(pid)).identityToken;
  }

  @override
  Future<bool> kill(
    final int pid, {
    final Duration grace = const Duration(seconds: 3),
  }) async {
    if (pid <= 0) return false;
    final String? originalIdentity;
    try {
      originalIdentity = await identityToken(pid);
    } on Object {
      return false;
    }
    if (originalIdentity == null || !Process.killPid(pid)) return false;
    await Future<void>.delayed(grace);
    try {
      if (!await isAlive(pid)) return true;
      if (await identityToken(pid) != originalIdentity) return false;
      // Windows has no POSIX signal distinction here; Dart maps this final
      // force rung to process termination on Windows.
      return Process.killPid(pid, ProcessSignal.sigkill);
    } on Object {
      return false;
    }
  }
}

/// A validated Windows process observation.
final class WindowsProcessSnapshot {
  /// Creates a validated observation from the machine GUID, boot time, and
  /// optional process creation time.
  const WindowsProcessSnapshot({
    required this.machineId,
    required this.bootTime,
    required this.processStartTime,
    required this.bootTimeIdentity,
    required this.processStartTimeIdentity,
  });

  /// Stable Windows installation identity from the MachineGuid registry key.
  final String machineId;

  /// Current host boot time.
  final DateTime bootTime;

  /// Process creation time, or null when the probe affirmatively found no
  /// process with the requested PID.
  final DateTime? processStartTime;

  /// Exact CIM boot timestamp used in the identity token.
  ///
  /// Kept separately from [bootTime] because Dart's [DateTime] precision is
  /// microseconds while Windows CIM timestamps can contain 100-nanosecond
  /// precision.
  final String bootTimeIdentity;

  /// Exact CIM process creation timestamp, or null when the process is
  /// missing.
  final String? processStartTimeIdentity;

  /// Whether this validated probe found the process.
  bool get isAlive => processStartTime != null;

  /// Token changing across process reuse, host reinstall, or reboot.
  String? get identityToken {
    final startTime = processStartTimeIdentity;
    if (startTime == null) return null;
    return 'windows|$machineId|$bootTimeIdentity|$startTime';
  }
}

/// Parses the one-line output from [windowsProcessProbeScript].
///
/// Malformed output and incomplete identities return null. The record format
/// is `alive|<MachineGuid>|<boot ISO timestamp>|<creation ISO timestamp>` or
/// `missing|<MachineGuid>|<boot ISO timestamp>|`.
WindowsProcessSnapshot? parseWindowsProcessProbeOutput(final String output) {
  final lines = output.trim().split(RegExp(r'\r?\n'));
  if (lines.length != 1) return null;
  final fields = lines.single.split('|');
  if (fields.length != 4) return null;

  final machineId = _parseWindowsMachineId(fields[1]);
  final bootTime = _parseWindowsUtcTimestamp(fields[2]);
  if (machineId == null || bootTime == null) return null;

  final DateTime? processStartTime;
  switch (fields[0]) {
    case 'missing':
      if (fields[3].isNotEmpty) return null;
      processStartTime = null;
    case 'alive':
      processStartTime = _parseWindowsUtcTimestamp(fields[3]);
      if (processStartTime == null) return null;
    default:
      return null;
  }
  return WindowsProcessSnapshot(
    machineId: machineId,
    bootTime: bootTime,
    processStartTime: processStartTime,
    bootTimeIdentity: fields[2],
    processStartTimeIdentity: fields[0] == 'alive' ? fields[3] : null,
  );
}

String? _parseWindowsMachineId(final String value) {
  if (!RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(value)) {
    return null;
  }
  return value.toLowerCase();
}

DateTime? _parseWindowsUtcTimestamp(final String value) {
  if (!value.endsWith('Z')) return null;
  final parsed = DateTime.tryParse(value);
  return parsed?.isUtc == true ? parsed : null;
}

/// PowerShell probe invoked with a validated numeric PID.
///
/// CIM supplies process `CreationDate` and `LastBootUpTime`; the MachineGuid
/// registry value scopes those times to this Windows installation. The
/// script emits a single machine-readable line and exits unsuccessfully if
/// any identity source cannot be read.
String windowsProcessProbeScript(final int pid) {
  if (pid <= 0) throw ArgumentError.value(pid, 'pid', 'Must be positive');
  return _windowsProcessProbeTemplate.replaceFirst('__PID__', '$pid');
}

const _windowsProcessProbeTemplate = r'''
$ErrorActionPreference = 'Stop'
$pidValue = __PID__
$os = Get-CimInstance -ClassName Win32_OperatingSystem
if ($null -eq $os -or $null -eq $os.LastBootUpTime) { exit 4 }
$registryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Cryptography')
if ($null -eq $registryKey) { exit 5 }
$machineId = [string]$registryKey.GetValue('MachineGuid')
if ([string]::IsNullOrWhiteSpace($machineId)) { exit 6 }
$boot = $os.LastBootUpTime.ToUniversalTime().ToString('o')
$process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $pidValue"
if ($null -eq $process) {
  [Console]::Out.WriteLine("missing|$machineId|$boot|")
  exit 0
}
if ($null -eq $process.CreationDate) { exit 7 }
$created = $process.CreationDate.ToUniversalTime().ToString('o')
[Console]::Out.WriteLine("alive|$machineId|$boot|$created")
''';

/// Extracts the process start time (field 22, `starttime` in clock ticks
/// since boot) from a Linux `/proc/<pid>/stat` record.
///
/// Pure and golden-testable (the registry tests exercise it even on macOS):
/// the comm field may contain spaces and parentheses, so parsing splits
/// after the *last* `)` — field 3 (state) is the first token after it, and
/// starttime is field 22, i.e. index 19 from there.
String? parseLinuxProcStatStarttime(final String stat) {
  final close = stat.lastIndexOf(')');
  if (close < 0) return null;
  final afterComm = stat.substring(close + 1).trim();
  if (afterComm.isEmpty) return null;
  final fields = afterComm.split(RegExp(r'\s+'));
  // fields[0] is stat field 3; starttime (field 22) is index 22 - 3 = 19.
  return fields.length > 19 ? fields[19] : null;
}

/// Combines Linux PID start ticks with the kernel boot UUID.
///
/// `/proc/<pid>/stat` start ticks are only unique within one boot. Including
/// the boot UUID prevents a stale pre-reboot lease from matching a recycled
/// PID after restart.
String? linuxProcessIdentityToken({
  required final String bootId,
  required final String stat,
}) {
  final normalizedBootId = bootId.trim();
  final startTicks = parseLinuxProcStatStarttime(stat);
  if (normalizedBootId.isEmpty || startTicks == null) return null;
  return '$normalizedBootId:$startTicks';
}
