import 'dart:async';

import 'package:oka_core/oka_core.dart';

/// Kills every live descendant of [supervisorPid] (subreaper adoptees). Repeats
/// until none remain or [budget] expires — needed because reparenting after the
/// workload root exits is not instantaneous.
Future<SubreaperDrainResult> drainSubreaperAdoptees({
  required int supervisorPid,
  ProcessTreeProbe probe = const HostProcessTreeProbe(),
  ProcessLiveness liveness = const HostProcessLiveness(),
  Duration budget = const Duration(seconds: 20),
  Duration poll = const Duration(milliseconds: 100),
  Duration killGrace = const Duration(milliseconds: 400),
}) async {
  final notes = <String>[];
  if (supervisorPid <= 0) {
    return const SubreaperDrainResult(
      settled: false,
      verified: false,
      survivors: [],
      notes: ['invalid supervisor pid'],
    );
  }

  final deadline = DateTime.now().add(budget);
  Duration remaining() {
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  Future<ProcessTree?> enumerateBounded() async {
    final left = remaining();
    if (left <= Duration.zero) {
      notes.add('enumerate skipped: budget exhausted');
      return null;
    }
    try {
      return await probe.enumerate(supervisorPid).timeout(left);
    } on TimeoutException {
      notes.add('enumerate timed out');
      return null;
    } on Object catch (e) {
      notes.add('enumerate failed: $e');
      return null;
    }
  }

  Future<bool?> isAliveBounded(int pid) async {
    final left = remaining();
    if (left <= Duration.zero) {
      notes.add('liveness inspect skipped for $pid: budget exhausted');
      return null;
    }
    try {
      return await liveness.isAlive(pid).timeout(left);
    } on TimeoutException {
      notes.add('liveness inspect timed out for $pid');
      return null;
    } on Object {
      notes.add('liveness inspect failed for $pid');
      return null;
    }
  }

  while (remaining() > Duration.zero) {
    final tree = await enumerateBounded();
    if (tree == null) {
      return SubreaperDrainResult(
        settled: false,
        verified: false,
        survivors: const [],
        notes: [...notes, 'process table unavailable during subreaper drain'],
      );
    }
    final descendants = tree.descendants();
    final alive = <int>[];
    for (final pid in descendants) {
      if (remaining() <= Duration.zero) {
        notes.add('incomplete descendant liveness inspection');
        return SubreaperDrainResult(
          settled: false,
          verified: false,
          survivors: alive,
          notes: notes,
        );
      }
      final aliveState = await isAliveBounded(pid);
      if (aliveState == null) {
        return SubreaperDrainResult(
          settled: false,
          verified: false,
          survivors: alive,
          notes: [...notes, 'incomplete descendant liveness inspection'],
        );
      }
      if (aliveState) alive.add(pid);
    }
    if (alive.isEmpty) {
      return SubreaperDrainResult(
        settled: true,
        verified: true,
        survivors: const [],
        notes: notes,
      );
    }
    for (final pid in alive.reversed) {
      if (remaining() <= Duration.zero) {
        notes.add('drain budget exhausted during kill pass');
        return SubreaperDrainResult(
          settled: false,
          verified: false,
          survivors: alive,
          notes: notes,
        );
      }
      final left = remaining();
      try {
        await liveness
            .kill(pid, grace: killGrace)
            .timeout(left, onTimeout: () => false);
      } on Object catch (e) {
        notes.add('kill $pid: $e');
      }
    }
    final delay = poll > remaining() ? remaining() : poll;
    if (delay <= Duration.zero) {
      notes.add('drain budget exhausted before poll delay');
      return SubreaperDrainResult(
        settled: false,
        verified: false,
        survivors: alive,
        notes: notes,
      );
    }
    await Future<void>.delayed(delay);
  }

  final tree = await enumerateBounded();
  if (tree == null) {
    return SubreaperDrainResult(
      settled: false,
      verified: false,
      survivors: const [],
      notes: [...notes, 'final enumerate unavailable'],
    );
  }
  final survivors = <int>[];
  for (final pid in tree.descendants()) {
    if (remaining() <= Duration.zero) {
      notes.add('incomplete final liveness inspection');
      return SubreaperDrainResult(
        settled: false,
        verified: false,
        survivors: survivors,
        notes: notes,
      );
    }
    final aliveState = await isAliveBounded(pid);
    if (aliveState == null) {
      return SubreaperDrainResult(
        settled: false,
        verified: false,
        survivors: survivors,
        notes: [...notes, 'incomplete final liveness inspection'],
      );
    }
    if (aliveState) survivors.add(pid);
  }
  if (survivors.isNotEmpty) {
    return SubreaperDrainResult(
      settled: false,
      verified: false,
      survivors: survivors,
      notes: [...notes, 'survivors remain after drain budget'],
    );
  }
  return SubreaperDrainResult(
    settled: true,
    verified: true,
    survivors: const [],
    notes: notes,
  );
}

final class SubreaperDrainResult {
  const SubreaperDrainResult({
    required this.settled,
    required this.verified,
    required this.survivors,
    this.notes = const [],
  });

  final bool settled;
  final bool verified;
  final List<int> survivors;
  final List<String> notes;
}
