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

  while (remaining() > Duration.zero) {
    ProcessTree? tree;
    try {
      tree = await probe
          .enumerate(supervisorPid)
          .timeout(remaining(), onTimeout: () => null);
    } on Object catch (e) {
      notes.add('enumerate failed: $e');
      tree = null;
    }
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
      if (remaining() <= Duration.zero) break;
      try {
        if (await liveness
            .isAlive(pid)
            .timeout(remaining(), onTimeout: () => true)) {
          alive.add(pid);
        }
      } on Object {
        alive.add(pid);
      }
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
      if (remaining() <= Duration.zero) break;
      try {
        await liveness
            .kill(pid, grace: killGrace)
            .timeout(remaining(), onTimeout: () => false);
      } on Object catch (e) {
        notes.add('kill $pid: $e');
      }
    }
    await Future<void>.delayed(
      poll > remaining() ? remaining() : poll,
    );
  }

  ProcessTree? tree;
  try {
    tree = await probe
        .enumerate(supervisorPid)
        .timeout(remaining(), onTimeout: () => null);
  } on Object {
    tree = null;
  }
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
    if (await liveness.isAlive(pid)) survivors.add(pid);
  }
  return SubreaperDrainResult(
    settled: false,
    verified: survivors.isEmpty,
    survivors: survivors,
    notes: [...notes, 'drain budget exhausted'],
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
