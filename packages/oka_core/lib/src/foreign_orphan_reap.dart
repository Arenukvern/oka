/// Foreign orphan reaping (ADR-0053): SIGKILL the orphan-prone dart/flutter
/// toolchain family whose parent died — the escapes no owned session or
/// lease covers (ADR-0052 is the prevention layer; this is the net).
///
/// Laws enforced here:
///
/// * **Family-limited** — only rows whose command line contains one of
///   [defaultForeignOrphanTargets] are candidates; the reaper never touches
///   anything else.
/// * **Orphans only** — the parent must be a supervisor, not a session:
///   `ppid == 1` (launchd/init) or a parent whose command line matches
///   [defaultForeignOrphanSupervisors] (Linux reparents user-session
///   orphans to the `systemd --user` subreaper, not pid 1). A parent
///   that cannot be resolved is somebody's session, not an escape.
/// * **Age floor** — matches younger than [minAge] are reported
///   [ForeignReapDisposition.skippedTooYoung], never signaled: compile
///   waves pass through the family's memory profile transiently.
/// * **Identity before signal** (ADR-0018 §1) — the start-time token
///   captured at scan time is re-verified through [verifyKillIdentity]
///   immediately before signaling; recycled ([KillIdentity.recycled]) and
///   unverifiable ([KillIdentity.unknown]) pids are never signaled.
/// * **Exclusions** — pids recorded live in [projectPath]'s lease registry
///   and rows matching [protectedNames] (registered residents, editor
///   tooling, oka's own p1 leaders) are never treated as foreign.
/// * **SIGKILL only** — machine-mode flutter tools trap SIGTERM and hang
///   (observed live), so the graceful-first ladder of
///   [ProcessLiveness.kill] is deliberately skipped for anonymous
///   processes (ADR-0053 §7).
/// * **Receipts** — every candidate resolves to a receipt with a named
///   disposition; death is verified after signaling and a survivor is
///   [ForeignReapDisposition.killFailed], never claimed success.
///
/// POSIX only (macOS/Linux): [readHostProcessTable] returns an empty table
/// on Windows rather than guessing.
library;

import 'dart:async';
import 'dart:io';

import 'process_lease_registry.dart';
import 'process_liveness.dart';
import 'process_surface.dart';

/// Command-line substrings identifying the orphan-prone flutter/dart
/// toolchain family (ADR-0053 §2). A process row is a candidate when its
/// full command line contains any of these. Only SDK-shipped artifacts
/// are defaults — machine-local ecosystem names (MCP servers, resident
/// daemons) compose in Dart at the call site ([reapForeignOrphans]'
/// `targetNames`), never in this list and never in a config file.
const defaultForeignOrphanTargets = <String>[
  'frontend_server_aot.dart.snapshot',
  'flutter_tools.snapshot',
  'development-service',
  'flutter_tester',
  'dartdev_aot.dart.snapshot',
];

/// Command-line substrings never reaped even when they match
/// [defaultForeignOrphanTargets]: editor-owned tooling and oka's own
/// self-settling p1 leaders (ADR-0053 §5). Machine-local residents
/// compose in Dart at the call site ([reapForeignOrphans]'
/// `protectedNames`).
const defaultForeignOrphanProtected = <String>[
  // Editor analysis servers are session-scoped tooling, not escapes.
  'language-server',
  // Oka's own leaders settle via the p1 host-eof contract (ADR-0052);
  // killing them here would mask a real contract gap.
  'owned_session_p1_leader',
];

/// Parent command-line signatures that mark a reparented orphan beyond
/// `ppid == 1`. On macOS launchd is pid 1; on Linux, `systemd --user`
/// registers as a child subreaper, so orphaned user-session processes
/// reparent to the user manager instead of init (ADR-0053 §3).
const defaultForeignOrphanSupervisors = <String>[
  'launchd',
  'systemd --user',
];

/// One host process-table row the reaper considered.
final class ForeignProcessRow {
  const ForeignProcessRow({
    required this.pid,
    required this.ppid,
    required this.command,
    required this.elapsed,
  });

  final int pid;

  /// Parent pid — `1` marks a launchd/init-reparented orphan.
  final int ppid;
  final String command;

  /// Time since process start (the `etime` column).
  final Duration elapsed;
}

/// How [reapForeignOrphans] resolved one candidate (the receipt's
/// disposition; ADR-0053 §8).
enum ForeignReapDisposition {
  /// Identity-verified SIGKILL delivered and death verified.
  killed,

  /// Dry run: candidate would be killed; nothing was signaled.
  wouldKill,

  /// Younger than the age floor.
  skippedTooYoung,

  /// Recorded live in the project lease registry — oka already owns it.
  skippedLeaseRecorded,

  /// Matches a protected name (registered resident, editor tooling, p1
  /// leader).
  skippedProtected,

  /// The start-time token changed between scan and signal — pid recycled;
  /// never signaled.
  skippedIdentityChanged,

  /// Identity could not be established — report, never guess.
  skippedUnverifiable,

  /// SIGKILL was delivered (identity verified) but the process survived.
  killFailed,
}

/// One candidate's resolution record.
final class ForeignReapReceipt {
  const ForeignReapReceipt({
    required this.pid,
    required this.command,
    required this.disposition,
    this.detail,
  });

  final int pid;
  final String command;
  final ForeignReapDisposition disposition;
  final String? detail;

  Map<String, Object?> toJson() => {
    'pid': pid,
    'command': command,
    'disposition': disposition.name,
    if (detail != null) 'detail': detail,
  };

  String toLine() {
    final detailSuffix = detail == null ? '' : ' — $detail';
    return 'pid $pid  ${disposition.name}$detailSuffix  $command';
  }
}

/// Outcome of one [reapForeignOrphans] pass.
final class ForeignReapSummary {
  const ForeignReapSummary({required this.receipts});

  final List<ForeignReapReceipt> receipts;

  int count(ForeignReapDisposition disposition) => receipts
      .where((r) => r.disposition == disposition)
      .length;

  /// Whether nothing needs human attention: successful kills are the sweep
  /// working, not a finding — only a failed kill or nothing-at-all here is
  /// notable. A dry run with candidates is also clean (audit outcome).
  bool get clean => count(ForeignReapDisposition.killFailed) == 0;

  /// Human lines for the CLI / doctor report.
  List<String> describeLines() {
    final lines = <String>[];
    final killed = receipts
        .where((r) => r.disposition == ForeignReapDisposition.killed)
        .toList();
    final wouldKill = receipts
        .where((r) => r.disposition == ForeignReapDisposition.wouldKill)
        .toList();
    final failed = receipts
        .where((r) => r.disposition == ForeignReapDisposition.killFailed)
        .toList();
    if (killed.isNotEmpty) {
      lines.add(
        'killed ${killed.length} foreign orphan(s): '
        '${killed.map((r) => 'pid ${r.pid}').join(', ')}',
      );
    }
    if (wouldKill.isNotEmpty) {
      lines.add(
        'dry-run: ${wouldKill.length} candidate(s) would be killed: '
        '${wouldKill.map((r) => 'pid ${r.pid}').join(', ')}',
      );
    }
    if (failed.isNotEmpty) {
      lines.add(
        'kill FAILED for ${failed.length} process(es) — still alive: '
        '${failed.map((r) => 'pid ${r.pid}').join(', ')}',
      );
    }
    for (final receipt in receipts) {
      switch (receipt.disposition) {
        case ForeignReapDisposition.skippedTooYoung:
        case ForeignReapDisposition.skippedLeaseRecorded:
        case ForeignReapDisposition.skippedProtected:
        case ForeignReapDisposition.skippedIdentityChanged:
        case ForeignReapDisposition.skippedUnverifiable:
          lines.add(receipt.toLine());
        case ForeignReapDisposition.killed:
        case ForeignReapDisposition.wouldKill:
        case ForeignReapDisposition.killFailed:
          break;
      }
    }
    if (receipts.isEmpty) {
      lines.add('no foreign orphans in the target family.');
    }
    return lines;
  }
}

/// Reads the host process table (`ps -axo pid=,ppid=,etime=,command=`).
/// Returns an empty table on Windows — foreign reaping is POSIX-only
/// (ADR-0053); nothing is scanned rather than guessed.
Future<List<ForeignProcessRow>> readHostProcessTable() async {
  if (Platform.isWindows) return const [];
  final result = await Process.run('ps', [
    '-axo',
    'pid=,ppid=,etime=,command=',
  ]);
  if (result.exitCode != 0) {
    return const [];
  }
  final rows = <ForeignProcessRow>[];
  for (final line in result.stdout.toString().split('\n')) {
    final row = parseForeignProcessRow(line);
    if (row != null) rows.add(row);
  }
  return rows;
}

/// Parses one `ps -axo pid=,ppid=,etime=,command=` line into a
/// [ForeignProcessRow]; malformed lines (headers, wrapped rows) return
/// null. Pure and golden-testable.
ForeignProcessRow? parseForeignProcessRow(String line) {
  final match = RegExp(r'^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$').firstMatch(
    line,
  );
  if (match == null) return null;
  final elapsed = parsePsEtime(match.group(3)!);
  if (elapsed == null) return null;
  return ForeignProcessRow(
    pid: int.parse(match.group(1)!),
    ppid: int.parse(match.group(2)!),
    command: match.group(4)!.trimRight(),
    elapsed: elapsed,
  );
}

/// Parses `ps` etime ([[dd-]hh:]mm:ss) into a [Duration]; malformed input
/// returns null. Pure and golden-testable.
Duration? parsePsEtime(String value) {
  final match = RegExp(r'^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$').firstMatch(
    value.trim(),
  );
  if (match == null) return null;
  final days = int.tryParse(match.group(1) ?? '0') ?? 0;
  final hours = int.tryParse(match.group(2) ?? '0') ?? 0;
  final minutes = int.tryParse(match.group(3) ?? '') ?? 0;
  final seconds = int.tryParse(match.group(4) ?? '') ?? 0;
  return Duration(
    days: days,
    hours: hours,
    minutes: minutes,
    seconds: seconds,
  );
}

/// Seam: the host process table reader (injectable for scripted-fake
/// tests; defaults to [readHostProcessTable]).
typedef ForeignProcessTableReader = Future<List<ForeignProcessRow>> Function();

/// Seam: delivers SIGKILL to a verified pid. Returns whether the signal
/// was delivered (not whether death completed — the caller verifies).
typedef ForeignOrphanKill = Future<bool> Function(int pid);

/// Seam: the pids recorded live in a lease registry — never treated as
/// foreign even when they match the target family.
typedef LiveLeasePidsReader = Future<Set<int>> Function();

/// The adopt-and-reap pass (ADR-0053). See the library docs for the laws.
///
/// ```dart
/// final summary = await reapForeignOrphans(Directory.current.path);
/// for (final line in summary.describeLines()) print(line);
/// ```
///
/// Machine-local family/protected policy is a Dart composition root
/// (ADR-0036 posture: thin shell, Dart drivers) — a driver file composes
/// this API with its own names; there is no yaml config surface:
///
/// ```dart
/// final summary = await reapForeignOrphans(
///   Directory.current.path,
///   targetNames: [
///     ...defaultForeignOrphanTargets,
///     'flutter-mcp-toolkit-server',
///   ],
///   protectedNames: [...defaultForeignOrphanProtected, 'my_warm_daemon'],
/// );
/// ```
Future<ForeignReapSummary> reapForeignOrphans(
  String projectPath, {
  ProcessLiveness? liveness,
  ForeignProcessTableReader? processTable,
  ForeignOrphanKill? killProcess,
  LiveLeasePidsReader? liveLeasePids,
  List<String> targetNames = defaultForeignOrphanTargets,
  List<String> protectedNames = defaultForeignOrphanProtected,
  List<String> supervisorNames = defaultForeignOrphanSupervisors,
  Duration minAge = const Duration(minutes: 15),
  bool dryRun = false,
  Duration deathCheckDelay = const Duration(milliseconds: 250),
}) async {
  final host = liveness ?? const HostProcessLiveness();
  final rows = await (processTable ?? readHostProcessTable)();
  final leased =
      await (liveLeasePids ?? () => _defaultLiveLeasePids(projectPath))();
  final rowByPid = {for (final r in rows) r.pid: r};

  /// Portable orphan gate (ADR-0053 §3): pid-1 reparenting, or a parent
  /// that is itself a supervisor (launchd is pid 1 on macOS, but on
  /// Linux the `systemd --user` subreaper adopts session orphans). An
  /// unresolvable parent is never treated as an escape.
  bool isOrphaned(ForeignProcessRow row) {
    if (row.ppid == 1) return true;
    final parent = rowByPid[row.ppid];
    if (parent == null) return false;
    return supervisorNames.any(parent.command.contains);
  }

  final receipts = <ForeignReapReceipt>[];
  for (final row in rows) {
    if (!isOrphaned(row)) continue;
    if (!targetNames.any(row.command.contains)) continue;

    ForeignReapReceipt skip(String? detail, ForeignReapDisposition d) =>
        ForeignReapReceipt(
          pid: row.pid,
          command: row.command,
          disposition: d,
          detail: detail,
        );

    if (protectedNames.any(row.command.contains)) {
      receipts.add(skip('protected name', ForeignReapDisposition.skippedProtected));
      continue;
    }
    if (leased.contains(row.pid)) {
      receipts.add(skip('recorded live in the lease registry', ForeignReapDisposition.skippedLeaseRecorded));
      continue;
    }
    if (row.elapsed < minAge) {
      receipts.add(skip('age ${row.elapsed.inMinutes}m < floor', ForeignReapDisposition.skippedTooYoung));
      continue;
    }

    // Identity before signal: capture at decision time, re-verify at
    // signal time through the same gate the lease surface uses.
    final String? token;
    try {
      token = await host.identityToken(row.pid);
    } on Object {
      receipts.add(skip('identity probe failed', ForeignReapDisposition.skippedUnverifiable));
      continue;
    }
    if (token == null) {
      receipts.add(skip('identity unobtainable (probably exited)', ForeignReapDisposition.skippedUnverifiable));
      continue;
    }
    final verdict = await verifyKillIdentity(host, row.pid, token);
    if (verdict == KillIdentity.recycled) {
      receipts.add(skip('pid recycled since scan — never signaled', ForeignReapDisposition.skippedIdentityChanged));
      continue;
    }
    if (verdict == KillIdentity.unknown) {
      receipts.add(skip('identity unverified — report, never guess', ForeignReapDisposition.skippedUnverifiable));
      continue;
    }

    if (dryRun) {
      receipts.add(
        ForeignReapReceipt(
          pid: row.pid,
          command: row.command,
          disposition: ForeignReapDisposition.wouldKill,
        ),
      );
      continue;
    }

    final delivered =
        await (killProcess ?? _sigkill)(row.pid);
    if (!delivered) {
      receipts.add(skip('SIGKILL could not be delivered', ForeignReapDisposition.killFailed));
      continue;
    }
    await Future<void>.delayed(deathCheckDelay);
    final stillAlive = await _isAliveOrUnverifiable(host, row.pid);
    receipts.add(
      ForeignReapReceipt(
        pid: row.pid,
        command: row.command,
        disposition: stillAlive
            ? ForeignReapDisposition.killFailed
            : ForeignReapDisposition.killed,
        detail: stillAlive ? 'survived SIGKILL' : null,
      ),
    );
  }
  return ForeignReapSummary(receipts: receipts);
}

/// Default kill seam: direct SIGKILL, skipping the graceful rung (ADR-0053
/// §7 — machine-mode flutter tools trap SIGTERM and hang).
Future<bool> _sigkill(int pid) async =>
    pid > 0 && (Process.killPid(pid, ProcessSignal.sigkill));

/// Liveness read that refuses to guess: an unavailable observation means
/// the death is NOT confirmed, so the receipt claims failure, never
/// success.
Future<bool> _isAliveOrUnverifiable(ProcessLiveness host, int pid) async {
  try {
    return await host.isAlive(pid);
  } on Object {
    return true;
  }
}

/// Default exclusion source: pids recorded live in [projectPath]'s lease
/// registry ([inventoryLeases]).
Future<Set<int>> _defaultLiveLeasePids(String projectPath) async {
  final entries = await inventoryLeases(projectPath);
  return {
    for (final e in entries)
      if (e.liveness == LeaseLiveness.live) e.lease.pid,
  };
}
