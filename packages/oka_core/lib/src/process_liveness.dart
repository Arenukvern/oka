/// Platform liveness / identity / kill seam (ADR-0018 §1).
///
/// macOS, Linux, and Windows answer "is this pid alive, and is it *still
/// the same* process?" differently, so the seam is abstracted from day one.
/// The default implementation ([HostProcessLiveness]) covers macOS and
/// Linux (the L0 evidence platforms); Windows throws
/// [UnimplementedError] with the same note on every member.
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

  /// Stops [pid] graceful-first: SIGTERM, wait up to [grace], SIGKILL if
  /// still alive. Returns false when the signal could not be sent at all
  /// (process already gone, unsupported platform).
  Future<bool> kill(final int pid, {final Duration grace});
}

/// Default [ProcessLiveness]: `ps` / `kill -0` on macOS, `/proc/<pid>/stat`
/// on Linux. Windows throws [UnimplementedError] on every member — L0
/// evidence targets macOS/Linux only; the throws are the documented L0
/// boundary, not a crash path (callers treat them as "identity
/// unobtainable", see [verifyKillIdentity]).
final class HostProcessLiveness implements ProcessLiveness {
  /// Const constructor — stateless.
  const HostProcessLiveness();

  static Never _windows() => throw UnimplementedError(
        'HostProcessLiveness: Windows is outside the L0 evidence surface '
        '(ADR-0018 phased plan) — liveness/identity/kill need a Windows '
        'implementation (e.g. WMI process CreationDate) before leases are '
        'reconciled there. Report-never-guess: callers must treat this as '
        '"identity unknown, never signal".',
      );

  @override
  Future<bool> isAlive(final int pid) async {
    if (pid <= 0) return false;
    if (Platform.isWindows) _windows();
    if (Platform.isLinux) return File('/proc/$pid').existsSync();
    final result = await Process.run('kill', ['-0', '$pid']);
    return result.exitCode == 0;
  }

  @override
  Future<String?> identityToken(final int pid) async {
    if (pid <= 0) return null;
    if (Platform.isWindows) _windows();
    if (Platform.isLinux) {
      final stat = await File('/proc/$pid/stat').readAsString();
      return parseLinuxProcStatStarttime(stat);
    }
    // macOS: `ps -o lstart= -p <pid>` — the process start time, stable for
    // the process's lifetime and different for every new process that
    // recycles the pid.
    final result = await Process.run('ps', ['-o', 'lstart=', '-p', '$pid']);
    final token = result.stdout.toString().trim();
    return token.isEmpty ? null : token;
  }

  @override
  Future<bool> kill(final int pid, {final Duration grace = const Duration(seconds: 3)}) async {
    if (pid <= 0) return false;
    if (Platform.isWindows) _windows();
    if (!Process.killPid(pid)) return false;
    await Future<void>.delayed(grace);
    if (await isAlive(pid)) {
      // Force is the *last* rung of the ladder (ADR-0018 §1); a process
      // that ignored SIGTERM for [grace] gets SIGKILL.
      Process.killPid(pid, ProcessSignal.sigkill);
    }
    return true;
  }
}

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
