/// Tree-aware process discovery and stop (ADR-0026 decision 8).
///
/// Dart's `Process.kill()` signals a single pid: when a child spawns its own
/// children, a leaked grandchild survives every per-pid stop path (the
/// failure class every surveyed system re-paid separately — mcp_flutter's
/// `pkill -P` ladder, the collector monorepo's reaper, the agent harness's
/// abandoned `dart test` children). This seam enumerates a process's live
/// subtree and stops it with the graceful→force ladder.
///
/// **Discovery constraint:** descendants are found by parent pid, and a dead
/// parent's children are reparented (pid 1 / launchd) and unfindable. Every
/// stop must therefore enumerate **before** the first signal.
///
/// **Authority:** only call [stopProcessTree] for a root the caller spawned
/// or holds a lease for (ADR-0018). Descendants inherit the root's kill
/// authority the same way `pkill -P` does; foreign subtrees are never swept.
library;

import 'dart:io';

import 'process_liveness.dart';

/// One discovered process: pid, parent pid, and an optional command
/// fragment kept for diagnostics only.
final class ProcessTreeNode {
  const ProcessTreeNode({
    required this.pid,
    required this.parentPid,
    this.command,
  });

  final int pid;
  final int parentPid;
  final String? command;
}

/// Snapshot of a process subtree rooted at [rootPid].
final class ProcessTree {
  const ProcessTree({required this.rootPid, required this.parentOf});

  final int rootPid;

  /// pid → parent pid for every discovered process (the root included when
  /// present in the table).
  final Map<int, int> parentOf;

  /// Live descendants of [rootPid], shallowest-first (breadth-first).
  List<int> descendants() {
    final children = <int, List<int>>{};
    parentOf.forEach((pid, parent) {
      children.putIfAbsent(parent, () => <int>[]).add(pid);
    });
    final result = <int>[];
    final queue = <int>[rootPid];
    final seen = <int>{rootPid};
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      for (final child in children[current] ?? const <int>[]) {
        if (seen.add(child)) {
          result.add(child);
          queue.add(child);
        }
      }
    }
    return result;
  }
}

/// Platform seam for subtree discovery, injectable for tests.
///
/// A seam, not a function: more members (subtree diffing) would be
/// speculative.
// ignore: one_member_abstracts
abstract interface class ProcessTreeProbe {
  /// Lists [rootPid]'s live subtree, or null when the process table cannot
  /// be read at all (callers must treat null as "unknown survivors", never
  /// as "no survivors").
  Future<ProcessTree?> enumerate(int rootPid);
}

/// Default probe: `ps -eo pid=,ppid=` on macOS/Linux, Windows PowerShell/CIM
/// on Windows.
final class HostProcessTreeProbe implements ProcessTreeProbe {
  /// Uses the platform commands unless a runner is supplied for testing.
  const HostProcessTreeProbe({this.commandRunner});

  /// Optional test seam. Leave unset to invoke the platform command.
  final ProcessCommandRunner? commandRunner;

  Future<ProcessResult> _run(String executable, List<String> arguments) =>
      commandRunner?.call(executable, arguments) ??
      Process.run(executable, arguments);

  @override
  Future<ProcessTree?> enumerate(int rootPid) async {
    if (rootPid <= 0) return ProcessTree(rootPid: rootPid, parentOf: const {});
    try {
      if (Platform.isWindows) {
        final result = await _run('powershell.exe', [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          windowsProcessTableScript,
        ]);
        if (result.exitCode != 0) return null;
        return ProcessTree(
          rootPid: rootPid,
          parentOf: parseWindowsProcessParentMap(result.stdout.toString()),
        );
      }
      final result = await _run('ps', ['-eo', 'pid=,ppid=']);
      if (result.exitCode != 0) return null;
      return ProcessTree(
        rootPid: rootPid,
        parentOf: parsePosixProcessParentMap(result.stdout.toString()),
      );
    } on Object {
      return null;
    }
  }
}

/// Parses `ps -eo pid=,ppid=` output into a pid → parent-pid map.
///
/// Pure and golden-testable; skips the header-free whitespace-padded rows
/// that do not parse as two integers.
Map<int, int> parsePosixProcessParentMap(final String output) {
  final parentOf = <int, int>{};
  for (final line in output.split('\n')) {
    final fields = line
        .trim()
        .split(RegExp(r'\s+'))
        .where((field) => field.isNotEmpty)
        .toList();
    if (fields.length < 2) continue;
    final pid = int.tryParse(fields[0]);
    final parent = int.tryParse(fields[1]);
    if (pid == null || parent == null || pid <= 0) continue;
    parentOf[pid] = parent;
  }
  return parentOf;
}

/// Parses the `pid|ppid` rows emitted by [windowsProcessTableScript].
Map<int, int> parseWindowsProcessParentMap(final String output) {
  final parentOf = <int, int>{};
  for (final line in output.split(RegExp(r'\r?\n'))) {
    final fields = line.trim().split('|');
    if (fields.length != 2) continue;
    final pid = int.tryParse(fields[0]);
    final parent = int.tryParse(fields[1]);
    if (pid == null || parent == null || pid <= 0) continue;
    parentOf[pid] = parent;
  }
  return parentOf;
}

/// PowerShell table probe: one `pid|ppid` row per process. Fails loudly on
/// an unavailable CIM so callers read "unknown", not "empty".
const windowsProcessTableScript = r'''
$ErrorActionPreference = 'Stop'
Get-CimInstance -ClassName Win32_Process | ForEach-Object {
  [Console]::Out.WriteLine("{0}|{1}" -f $_.ProcessId, $_.ParentProcessId)
}
''';

/// Result of a tree stop. [survivors] lists pids still alive after the
/// ladder — empty means verified dead, never assumed.
final class TreeStopResult {
  const TreeStopResult({
    required this.stopped,
    required this.survivors,
    this.notes = const <String>[],
  });

  /// True when [survivors] is empty after the final verification round.
  final bool stopped;
  final List<int> survivors;
  final List<String> notes;
}

/// Stops [rootPid] and its live descendants with the graceful→force ladder.
///
/// The caller must own the root (spawned it, or holds its lease). The root
/// is identity-gated when [rootIdentityToken] was captured at spawn time
/// ([verifyKillIdentity]); a recycled or unverifiable root is **refused**
/// and nothing is signaled. Descendants are discovered before the first
/// signal (see the library docs), signaled SIGTERM in one pass, then
/// re-enumerated after [grace]; survivors get the full [ProcessLiveness.kill]
/// ladder for [forceRounds] rounds, then a final verification.
Future<TreeStopResult> stopProcessTree({
  required final ProcessTreeProbe probe,
  required final ProcessLiveness liveness,
  required final int rootPid,
  final String? rootIdentityToken,
  final Duration grace = const Duration(seconds: 3),
  final Duration settle = const Duration(milliseconds: 250),
  final int forceRounds = 2,
}) async {
  if (rootPid <= 0) {
    return const TreeStopResult(
      stopped: false,
      survivors: <int>[],
      notes: <String>['invalid root pid'],
    );
  }
  final notes = <String>[];

  // Enumerate FIRST — a dead parent's children reparent and vanish from
  // this discovery path (library docs).
  final tree = await probe.enumerate(rootPid);
  if (tree == null) {
    notes.add('process table unavailable; survivors unknown');
    return TreeStopResult(stopped: false, survivors: const <int>[], notes: notes);
  }
  final descendants = tree.descendants();

  // Root first so it cannot spawn more children while we work downward.
  if (await liveness.isAlive(rootPid)) {
    if (rootIdentityToken != null) {
      final verdict = await verifyKillIdentity(
        liveness,
        rootPid,
        rootIdentityToken,
      );
      if (verdict != KillIdentity.verified) {
        notes.add(
          'root identity $verdict; refused to signal (report-never-guess)',
        );
        return TreeStopResult(
          stopped: false,
          survivors: <int>[rootPid, ...descendants],
          notes: notes,
        );
      }
    }
    await liveness.kill(rootPid, grace: grace);
  }

  // One SIGTERM pass over the discovered descendants, shallowest-first.
  for (final pid in descendants) {
    if (await liveness.isAlive(pid)) {
      Process.killPid(pid);
    }
  }
  await Future<void>.delayed(grace);

  var survivors = await _remaining(probe, liveness, rootPid);
  for (var round = 0; round < forceRounds && survivors.isNotEmpty; round++) {
    for (final pid in survivors) {
      // Full ladder per survivor: SIGTERM → grace → SIGKILL internally.
      await liveness.kill(pid, grace: grace);
    }
    await Future<void>.delayed(settle);
    survivors = await _remaining(probe, liveness, rootPid);
  }
  if (survivors.isNotEmpty) {
    notes.add('${survivors.length} survivor(s) after the force ladder');
  }
  return TreeStopResult(
    stopped: survivors.isEmpty,
    survivors: survivors,
    notes: notes,
  );
}

/// Liveness sweep over the root and its currently-discoverable subtree. An
/// unprobeable pid counts as a survivor: report-never-guess (ADR-0018).
Future<List<int>> _remaining(
  ProcessTreeProbe probe,
  ProcessLiveness liveness,
  int rootPid,
) async {
  final tree = await probe.enumerate(rootPid);
  if (tree == null) return const <int>[];
  final alive = <int>[];
  for (final pid in <int>[rootPid, ...tree.descendants()]) {
    try {
      if (await liveness.isAlive(pid)) alive.add(pid);
    } on Object {
      alive.add(pid);
    }
  }
  return alive;
}
