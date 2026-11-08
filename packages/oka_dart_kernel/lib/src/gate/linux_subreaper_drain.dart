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
  final deadline = DateTime.now().add(budget);
  final survivors = <int>{};

  while (DateTime.now().isBefore(deadline)) {
    if (supervisorPid <= 0) {
      notes.add('invalid supervisor pid');
      break;
    }
    final tree = await probe.enumerate(supervisorPid);
    if (tree == null) {
      notes.add('process table unavailable during subreaper drain');
      survivors.addAll(survivors);
      break;
    }
    final descendants = tree.descendants();
    final alive = <int>[];
    for (final pid in descendants) {
      if (await liveness.isAlive(pid)) alive.add(pid);
    }
    if (alive.isEmpty) {
      return SubreaperDrainResult(
        settled: true,
        survivors: const [],
        notes: notes,
      );
    }
    for (final pid in alive.reversed) {
      await liveness.kill(pid, grace: killGrace);
    }
    survivors
      ..clear()
      ..addAll(alive);
    await Future<void>.delayed(poll);
  }

  final tree = supervisorPid > 0 ? await probe.enumerate(supervisorPid) : null;
  if (tree != null) {
    for (final pid in tree.descendants()) {
      if (await liveness.isAlive(pid)) survivors.add(pid);
    }
  }

  return SubreaperDrainResult(
    settled: survivors.isEmpty,
    survivors: survivors.toList(),
    notes: notes,
  );
}

final class SubreaperDrainResult {
  const SubreaperDrainResult({
    required this.settled,
    required this.survivors,
    this.notes = const [],
  });

  final bool settled;
  final List<int> survivors;
  final List<String> notes;
}
