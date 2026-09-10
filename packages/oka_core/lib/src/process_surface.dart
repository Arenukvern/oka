/// The lease lifecycle surface (ADR-0018 §4/L1): inspect and stop leases
/// across runs — the machine-and-human backing of `oka processes list` and
/// `oka stop`.
///
/// Everything here is registry + seam logic in `oka_core` so the CLI stays
/// parse-and-delegate (ADR-0015) and the semantics are unit-testable with
/// scripted fakes. Cross-run state rides the lease registry only — never a
/// daemon (ADR-0001 posture, ADR-0018 §1).
///
/// Laws enforced here:
///
/// * **Identity over pid** — a lease is stopped only after
///   [ProcessLeaseRegistry.checkLiveness] says [LeaseLiveness.live];
///   recycled pids are never signaled (the stale record is dropped
///   instead).
/// * **Ownership** — teardown stops only `owned` leases (ADR-0018 §3);
///   a borrowed lease is refused unless [stopLease]'s `force` is set (an
///   explicit human/agent override naming the risk).
/// * **Report, never guess** — an unverifiable lease (`unknown`) is
///   reported, not signaled.
library;

import 'dart:async';
import 'dart:io';

import 'process_lease.dart';
import 'process_lease_registry.dart';
import 'process_liveness.dart';

/// One entry of the lease inventory ([inventoryLeases]): the record plus
/// its reconcile verdict against the live host.
final class LeaseInventoryEntry {
  const LeaseInventoryEntry({required this.lease, required this.liveness});

  final ProcessLease lease;

  /// [LeaseLiveness.live], [LeaseLiveness.deadPid] (stale, safe to drop),
  /// [LeaseLiveness.reusedPid] (stale, pid recycled — never signal) or
  /// [LeaseLiveness.unknown] (report, never guess).
  final LeaseLiveness liveness;

  /// Machine form (the `leases` array of the `processes.inventory` event).
  Map<String, Object?> toJson() => {
        ...lease.toJson(),
        'liveness': switch (liveness) {
          LeaseLiveness.live => 'live',
          LeaseLiveness.deadPid => 'dead_pid',
          LeaseLiveness.reusedPid => 'reused_pid',
          LeaseLiveness.unknown => 'unknown',
        },
      };

  /// One human-readable line (`oka processes list` default rendering).
  String toLine() {
    final verdict = switch (liveness) {
      LeaseLiveness.live => 'running',
      LeaseLiveness.deadPid => 'stale (process gone)',
      LeaseLiveness.reusedPid => 'stale (pid recycled)',
      LeaseLiveness.unknown => 'identity unknown',
    };
    final ident = lease.identity.entries
        .where((final e) => e.key != processLeasePidTokenKey)
        .map((final e) => '${e.key}=${e.value}')
        .join(' ');
    return '${lease.id}  pid ${lease.pid}  ${lease.kind}  '
        '${lease.ownership.label}/${lease.scope.label}  $verdict'
        '${ident.isEmpty ? '' : '  ($ident)'}';
  }
}

/// The reconcile + listing of every lease in [projectPath]'s registry.
/// Corrupt records are skipped by the registry; dead/recycled ones stay
/// listed (marked stale) — deletion is [stopLease]'s or the L2 sweep's
/// decision, never a surprise during inspection.
///
/// Backs `oka processes list` (parse-and-delegate, ADR-0015):
///
/// ```dart
/// final entries = await inventoryLeases(projectPath);
/// for (final e in entries) {
///   print(e.toLine()); // 'emulator-oka-emulator  pid 4242  …  running'
/// }
/// final json = [for (final e in entries) e.toJson()]; // tooling form
/// ```
Future<List<LeaseInventoryEntry>> inventoryLeases(
  final String projectPath, {
  final ProcessLiveness? liveness,
}) async {
  final registry =
      ProcessLeaseRegistry.forProject(projectPath, liveness: liveness);
  final entries = <LeaseInventoryEntry>[];
  for (final lease in await registry.list()) {
    entries.add(
      LeaseInventoryEntry(
        lease: lease,
        liveness: await registry.checkLiveness(lease),
      ),
    );
  }
  return entries;
}

/// How [stopLease] resolved (the `action` field of `stop.result`).
enum LeaseStopAction {
  /// The process was stopped via its `stop_hint` and the lease removed.
  stopped,

  /// The process was already gone (or its pid recycled) — only the stale
  /// record was removed.
  recordDropped,

  /// Refused: borrowed lease (or unverified identity) — report, never
  /// guess, per ADR-0018 §1/§3.
  refused,

  /// The graceful stop ran but the process would not die and the force
  /// rung was unavailable/unsuccessful. The lease stays for the reconcile
  /// sweep.
  failed,
}

/// Result of [stopLease].
final class LeaseStopOutcome {
  const LeaseStopOutcome({required this.ok, required this.action, this.error});

  final bool ok;
  final LeaseStopAction action;
  final String? error;
}

/// Stops the lease [id] in [projectPath]'s registry, identity-verified and
/// graceful-first (ADR-0018 §1):
///
/// 1. hint-only records (pid 0, semantic discovery) → the graceful hint is
///    both truth-check and stop path;
/// 2. stale records (`deadPid` / `reusedPid`) → record dropped, nothing
///    signaled;
/// 3. `unknown` identity → refused (report, never guess);
/// 4. `borrowed` ownership → refused unless [force] (explicit override
///    naming the risk);
/// 5. `live` + owned → run the graceful `stop_hint` command, verify the
///    pid dies within [stopVerifyGrace], escalate via
///    [ProcessLiveness.kill] if it ignored the graceful path, then delete
///    the lease.
///
/// Backs `oka stop <id>`:
///
/// ```dart
/// final outcome = await stopLease(projectPath, 'emulator-oka-emulator');
/// if (!outcome.ok) {
///   stderr.writeln(outcome.error); // names the law that refused
/// } else {
///   print('stopped: ${outcome.action.name}');
/// }
/// ```
Future<LeaseStopOutcome> stopLease(
  final String projectPath,
  final String id, {
  final ProcessLiveness? liveness,
  final bool force = false,
  final Duration stopVerifyGrace = const Duration(seconds: 5),
  final Duration pollInterval = const Duration(milliseconds: 200),
  final Future<ProcessResult> Function(String, List<String>)? runProcess,
}) async {
  final host = liveness ?? const HostProcessLiveness();
  final registry = ProcessLeaseRegistry.forProject(projectPath, liveness: host);
  final lease = await registry.read(id);
  if (lease == null) {
    return LeaseStopOutcome(
      ok: false,
      action: LeaseStopAction.refused,
      error: "No process lease '$id' in this project — "
          '`oka processes list` shows the recorded ids.',
    );
  }

  final run = runProcess ?? Process.run;

  // Hint-only path (pid 0 — semantic discovery adopted this process, e.g.
  // a borrowed emulator): liveness can't verify it, so the graceful hint
  // (e.g. `adb -s <serial> emu kill`) is both the truth-check and the
  // stop path. An empty hint means there is nothing safe to signal.
  if (lease.pid <= 0) {
    if (lease.stopHint.args.isEmpty) {
      return LeaseStopOutcome(
        ok: false,
        action: LeaseStopAction.refused,
        error: "Lease '$id' carries no pid and no stop hint — nothing safe "
            'to signal. Drop the stale record manually or let the L2 '
            'reconcile sweep clean it.',
      );
    }
    final result = await _runHint(run, lease.stopHint.tool, lease.stopHint.args, lease);
    if (result.$1) {
      return LeaseStopOutcome(
        ok: false,
        action: LeaseStopAction.failed,
        error: result.$2,
      );
    }
    await registry.delete(lease.id);
    return const LeaseStopOutcome(ok: true, action: LeaseStopAction.stopped);
  }

  // pid > 0: identity reconcile first (dead / recycled → drop the record,
  // never signal).
  final verdict = await registry.checkLiveness(lease);
  if (verdict == LeaseLiveness.deadPid || verdict == LeaseLiveness.reusedPid) {
    await registry.delete(id);
    return const LeaseStopOutcome(ok: true, action: LeaseStopAction.recordDropped);
  }
  if (verdict == LeaseLiveness.unknown) {
    return LeaseStopOutcome(
      ok: false,
      action: LeaseStopAction.refused,
      error: "Lease '$id' identity could not be verified — not signaled "
          '(report-never-guess, ADR-0018 §1). The record is kept for the '
          'reconcile sweep.',
    );
  }
  if (lease.ownership == LeaseOwnership.borrowed && !force) {
    return LeaseStopOutcome(
      ok: false,
      action: LeaseStopAction.refused,
      error: "Lease '$id' is borrowed (adopted by reuse, not spawned by "
          'the last run) — teardown stops only owned leases (ADR-0018 §3). '
          'Stop the owning terminal instead, or re-run with --force to '
          'override explicitly.',
    );
  }

  // Graceful-first: run the recorded stop hint (adb emu kill, kill pid, …).
  final hint = lease.stopHint;
  final hintFailed = await _runHint(run, hint.tool, hint.args, lease);
  final hintResult = hintFailed.$1 ? null : hintFailed.$3;

  // Verify death within the grace window; escalate if the process ignored
  // the graceful path (last rung of the ADR-0018 §1 ladder).
  var gone = !(await host.isAlive(lease.pid));
  final deadline = DateTime.now().add(stopVerifyGrace);
  while (!gone && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(pollInterval);
    gone = !(await host.isAlive(lease.pid));
  }
  if (!gone && !await host.kill(lease.pid, grace: stopVerifyGrace)) {
    return LeaseStopOutcome(
      ok: false,
      action: LeaseStopAction.failed,
      error: "Lease '${lease.id}': graceful stop ran (exit "
          '${hintResult?.exitCode}) but pid ${lease.pid} is still alive; '
          'lease kept for reconciliation.',
    );
  }
  await registry.delete(lease.id);
  return const LeaseStopOutcome(ok: true, action: LeaseStopAction.stopped);
}

/// Runs the graceful stop hint, converting a missing/failed tool into a
/// typed outcome instead of a thrown [ProcessException] — the stop must
/// degrade to "reported", never crash the CLI. Returns
/// `(failed, message, result)`.
Future<(bool, String, ProcessResult?)> _runHint(
  final Future<ProcessResult> Function(String, List<String>) run,
  final String tool,
  final List<String> args,
  final ProcessLease lease,
) async {
  final ProcessResult result;
  try {
    result = await run(tool, args);
  } on ProcessException catch (e) {
    return (
      true,
      "Lease '${lease.id}': stop tool '$tool' could not run — $e. "
          'fix: install the tool (e.g. Android platform-tools for adb) or '
          'stop the process manually; the lease is kept for reconciliation.',
      null,
    );
  }
  if (result.exitCode != 0) {
    return (
      true,
      "Lease '${lease.id}': $tool ${args.join(' ')} exited "
          '${result.exitCode} — ${result.stderr}'.trim(),
      result,
    );
  }
  return (false, '', result);
}

/// Summary of the L2 reconcile sweep ([reconcileLeases]) — the crash-
/// recovery pass that runs at doctor/CLI-inspection time.
final class LeaseReconcileSummary {
  const LeaseReconcileSummary({
    this.droppedStale = const [],
    this.orphans = const [],
    this.borrowed = const [],
    this.persistent = const [],
    this.unverifiable = const [],
  });

  /// Lease ids whose records were provably stale (process gone or pid
  /// recycled) — records dropped, nothing was ever signaled by identity.
  final List<String> droppedStale;

  /// Live `owned` + `ephemeral` leases — the owning run exited without
  /// stopping them. Reported, not auto-stopped (see [reconcileLeases]).
  final List<String> orphans;

  /// Live borrowed leases — another terminal's session; never touched.
  final List<String> borrowed;

  /// Live `persistent` leases — intentional survivors.
  final List<String> persistent;

  /// Identity could not be established — reported, kept for a later sweep
  /// (report-never-guess, ADR-0018 §1).
  final List<String> unverifiable;

  /// Whether nothing needs human attention (dropping stale records is the
  /// sweep working, not a finding).
  bool get clean => orphans.isEmpty && unverifiable.isEmpty;

  /// Human lines for the doctor / sweep report.
  List<String> describeLines() {
    final lines = <String>[];
    if (droppedStale.isNotEmpty) {
      final ids = droppedStale.join(', ');
      lines.add(
        'dropped ${droppedStale.length} stale record(s): $ids',
      );
    }
    if (orphans.isNotEmpty) {
      final ids = orphans.join(', ');
      lines.add(
        'orphaned (owning run exited): $ids — `oka stop <id>` to stop them',
      );
    }
    if (borrowed.isNotEmpty) {
      final ids = borrowed.join(', ');
      lines.add('borrowed (other terminal): $ids — untouched');
    }
    if (persistent.isNotEmpty) {
      final ids = persistent.join(', ');
      lines.add('persistent (kept): $ids');
    }
    if (unverifiable.isNotEmpty) {
      final ids = unverifiable.join(', ');
      lines.add(
        'identity unverified: $ids — kept, never signaled',
      );
    }
    if (clean) lines.add('no leases recorded (or all clean).');
    return lines;
  }
}

/// The L2 reconcile sweep (ADR-0018 §5): reconcile every lease in
/// [projectPath] against the live host.
///
/// * Provably stale records (`deadPid` / `reusedPid`) are dropped — the
///   one mutation inspection-time sweeps perform automatically, and the
///   piece that makes crash/SIGKILL recovery converge.
/// * Live leases are classified and **reported**, never auto-stopped by
///   default: `oka run emulator`'s default posture deliberately leaves the
///   emulator up for reuse, so an owned+ephemeral live lease is flagged as
///   an orphan-suspect (`oka stop <id>` is the explicit stop). Pass
///   [stopOrphans] to harden this for hermetic harnesses (CI tiers) where
///   orphans from a dead run are stopped through the same identity-graded
///   laws as [stopLease].
///
/// Backs the doctor audit block and `oka stop --stale`:
///
/// ```dart
/// final sweep = await reconcileLeases(projectPath);
/// for (final line in sweep.describeLines()) {
///   print(line); // 'dropped 1 stale record(s): …', 'orphaned (owning run
///                //  exited): … — `oka stop <id>` to stop them', …
/// }
/// ```
Future<LeaseReconcileSummary> reconcileLeases(
  final String projectPath, {
  final ProcessLiveness? liveness,
  final bool stopOrphans = false,
  final Duration stopVerifyGrace = const Duration(seconds: 5),
  final Future<ProcessResult> Function(String, List<String>)? runProcess,
}) async {
  final host = liveness ?? const HostProcessLiveness();
  final entries = await inventoryLeases(projectPath, liveness: host);
  final dropped = <String>[];
  final orphans = <String>[];
  final borrowed = <String>[];
  final persistent = <String>[];
  final unverifiable = <String>[];
  for (final e in entries) {
    switch (e.liveness) {
      case LeaseLiveness.deadPid:
      case LeaseLiveness.reusedPid:
        // Provably stale (or pid recycled — never signal): drop the record.
        await ProcessLeaseRegistry.forProject(
          projectPath,
          liveness: host,
        ).delete(e.lease.id);
        dropped.add(e.lease.id);
      case LeaseLiveness.unknown:
        unverifiable.add(e.lease.id);
      case LeaseLiveness.live:
        if (e.lease.ownership == LeaseOwnership.borrowed) {
          borrowed.add(e.lease.id);
        } else if (e.lease.scope == LeaseScope.persistent) {
          persistent.add(e.lease.id);
        } else {
          orphans.add(e.lease.id);
          if (stopOrphans && e.lease.pid > 0) {
            await stopLease(
              projectPath,
              e.lease.id,
              liveness: host,
              stopVerifyGrace: stopVerifyGrace,
              runProcess: runProcess,
            );
          }
        }
    }
  }
  return LeaseReconcileSummary(
    droppedStale: dropped,
    orphans: orphans,
    borrowed: borrowed,
    persistent: persistent,
    unverifiable: unverifiable,
  );
}
