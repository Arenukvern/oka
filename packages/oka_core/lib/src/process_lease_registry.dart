/// The process-lease registry (ADR-0018 §1): a directory of JSON files, one
/// per lease, under `<project>/.oka_cache/processes/<id>.json`.
///
/// Leases are **advisory records, not a supervisor** — no daemon, no
/// server, no background process (the ADR-0001 no-daemon posture holds).
/// Concurrency safety is atomic write-then-rename, nothing more: an
/// upsert writes to a unique temp file, flushes, then renames over the
/// target, so a reader never sees a half-written lease and a crash mid-
/// write leaves at most an orphaned `.tmp` (which [list] ignores).
///
/// The registry is the *only* state that survives across runs (ADR-0018
/// §2) — which is what makes crash/SIGKILL reconciliation possible at all:
/// the next oka invocation reads these files, liveness- and identity-checks
/// each record ([checkLiveness]), and reports (or, from L2, stops) stale
/// entries.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'process_lease.dart';
import 'process_liveness.dart';

/// Durable, advisory registry of [ProcessLease] records under
/// [directory] (`<project>/.oka_cache/processes/`).
///
/// All registry errors on the write path are the caller's to surface —
/// spawn steps treat lease failures as advisory (a failed lease write must
/// never fail a build that otherwise succeeded).
///
/// Usage:
///
/// ```dart
/// final registry = ProcessLeaseRegistry.forProject(projectPath);
/// await registry.upsert(lease);                 // atomic write-then-rename
/// final live = await registry.list();           // all valid records, sorted
/// final verdict = await registry.checkLiveness(lease);
/// if (verdict == LeaseLiveness.live) { /* safe to consider stopping */ }
/// await registry.delete(lease.id);              // remove the record
/// ```
final class ProcessLeaseRegistry {
  /// Creates a registry over [directory] (created lazily on first write).
  /// [liveness] defaults to [HostProcessLiveness]; tests inject fakes.
  ProcessLeaseRegistry(this.directory, {final ProcessLiveness? liveness})
      : _liveness = liveness ?? const HostProcessLiveness();

  /// Registry rooted at the standard project location:
  /// `<projectPath>/.oka_cache/processes/`.
  factory ProcessLeaseRegistry.forProject(
    final String projectPath, {
    final ProcessLiveness? liveness,
  }) =>
      ProcessLeaseRegistry(
        Directory(p.absolute(projectPath, '.oka_cache', 'processes')),
        liveness: liveness,
      );

  /// The lease directory (`<project>/.oka_cache/processes`).
  final Directory directory;

  final ProcessLiveness _liveness;

  /// The lease file for [id] (`<id>.json`).
  File _leaseFile(final String id) =>
      File(p.absolute(directory.path, '$id.json'));

  /// Writes (or replaces) [lease] atomically: write a unique temp file,
  /// flush, rename over the target.
  Future<void> upsert(final ProcessLease lease) async {
    await directory.create(recursive: true);
    final target = _leaseFile(lease.id);
    final tmp = File(
      p.absolute(directory.path, '${lease.id}.json'
          '.${DateTime.now().microsecondsSinceEpoch}.tmp'),
    );
    try {
      await tmp.writeAsString(lease.toJsonString(), flush: true);
      await tmp.rename(target.path);
    } on Object {
      // Never leave temp litter behind on a failed write.
      if (tmp.existsSync()) tmp.deleteSync();
      rethrow;
    }
  }

  /// Reads the lease with [id], or null when absent.
  Future<ProcessLease?> read(final String id) async {
    final file = _leaseFile(id);
    if (!file.existsSync()) return null;
    return ProcessLease.fromJsonString(await file.readAsString());
  }

  /// All valid lease records, sorted by id. Corrupt records (crash
  /// mid-write of a pre-rename file, manual tampering) are skipped and
  /// reported on stdout — they are exactly the stale entries the L2
  /// reconcile sweep exists to clean up, never a crash.
  Future<List<ProcessLease>> list() async {
    if (!directory.existsSync()) return const [];
    final leases = <ProcessLease>[];
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.json')) continue;
      try {
        leases.add(ProcessLease.fromJsonString(entity.readAsStringSync()));
      } on FormatException catch (e) {
        // Advisory registry: a corrupt record is reported, never fatal.
        print('⚠️ Skipping corrupt lease record ${entity.path}: ${e.message}');
      } on FileSystemException catch (e) {
        print('⚠️ Skipping unreadable lease record ${entity.path}: '
            '${e.message}');
      }
    }
    final sorted = leases.toList()..sort((final a, final b) => a.id.compareTo(b.id));
    return sorted;
  }

  /// Deletes the lease with [id]. Returns whether a record existed.
  Future<bool> delete(final String id) async {
    final file = _leaseFile(id);
    if (!file.existsSync()) return false;
    await file.delete();
    return true;
  }

  /// Liveness + identity reconciliation of one lease against the host
  /// (ADR-0018 §1/§5, the crash-recovery primitive):
  ///
  /// * pid unknown (`0`) or dead → [LeaseLiveness.deadPid] — the leased
  ///   process is gone; the record is stale and safe to delete.
  /// * pid alive but the start-time token differs →
  ///   [LeaseLiveness.reusedPid] — pid recycling; the record is stale and
  ///   the pid must **never** be signaled.
  /// * pid alive with no recorded token (spawn-time token unobtainable) →
  ///   [LeaseLiveness.unknown] — report, never guess.
  /// * pid alive and token matches → [LeaseLiveness.live].
  Future<LeaseLiveness> checkLiveness(final ProcessLease lease) async {
    if (lease.pid <= 0) return LeaseLiveness.deadPid;
    final bool alive;
    try {
      alive = await _liveness.isAlive(lease.pid);
    } on Object {
      return LeaseLiveness.unknown;
    }
    if (!alive) return LeaseLiveness.deadPid;
    final recorded = lease.identity[processLeasePidTokenKey];
    if (recorded == null) return LeaseLiveness.unknown;
    final String? current;
    try {
      current = await _liveness.identityToken(lease.pid);
    } on Object {
      return LeaseLiveness.unknown;
    }
    if (current == null) return LeaseLiveness.unknown;
    return current == recorded
        ? LeaseLiveness.live
        : LeaseLiveness.reusedPid;
  }
}

/// Liveness verdict for a lease record ([ProcessLeaseRegistry.checkLiveness]).
enum LeaseLiveness {
  /// The process is alive and its identity matches the lease.
  live,

  /// The leased pid is gone (process exited, or the lease has no pid) —
  /// stale record, safe to delete.
  deadPid,

  /// The pid is alive but is no longer the leased process (pid recycling)
  /// — stale record, must never be killed.
  reusedPid,

  /// Identity could not be established — report, never guess.
  unknown;

  /// Whether the record is stale (anything other than [live]).
  bool get isStale => this != live;
}
