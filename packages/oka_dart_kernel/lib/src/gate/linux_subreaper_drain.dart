import 'dart:async';
import 'dart:io';

import 'package:oka_core/oka_core.dart';

import 'linux_proc_process_tree_probe.dart';
import 'linux_proc_state.dart';
import 'linux_subreaper_drain_receipt.dart';
import 'linux_subreaper_reap.dart';

/// Pids reparented directly under a child subreaper ([supervisorPid]).
List<int> directSubreaperAdoptees(ProcessTree tree, int supervisorPid) => [
      for (final entry in tree.parentOf.entries)
        if (entry.value == supervisorPid) entry.key,
    ];

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
  Future<void> Function(SubreaperDrainReceipt receipt)? onReceipt,
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
  var sawAliveAdoptee = false;
  var enumerateSource = Platform.isLinux ? '/proc' : 'ps';
  var preferProcEnumerate = Platform.isLinux;
  Map<int, int>? procParentCache;
  DateTime? procParentCacheAt;
  var totalReaped = 0;
  var emptyDescendantPolls = 0;
  String? _lastEnumerateReceiptKey;

  Duration remaining() {
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  Future<void> receipt(
    String phase, {
    List<int> inspectPids = const [],
    List<String> errors = const [],
  }) async {
    if (phase == 'enumerate') {
      final key = inspectPids.join(',');
      if (key == _lastEnumerateReceiptKey && errors.isEmpty) return;
      _lastEnumerateReceiptKey = key;
    }
    final obs = <String>[
      for (final pid in inspectPids)
        if (linuxProcDiagLabel(pid) != null) linuxProcDiagLabel(pid)!,
    ];
    final emit = onReceipt;
    if (emit != null) {
      await emit(
        SubreaperDrainReceipt(
          phase: phase,
          remainingMs: remaining().inMilliseconds,
          observations: obs,
          errors: errors,
          reapedZombies: totalReaped,
          enumerateSource: enumerateSource,
        ),
      );
    }
  }

  ProcessTree? enumerateLinuxProcSync() {
    if (!Platform.isLinux) return null;
  if (procParentCache != null &&
      procParentCacheAt != null &&
      DateTime.now().difference(procParentCacheAt!) <
          const Duration(milliseconds: 300)) {
    enumerateSource = '/proc';
    return ProcessTree(rootPid: supervisorPid, parentOf: procParentCache!);
  }
    try {
      final parentOf = buildLinuxProcParentMap();
      if (parentOf.isEmpty) return null;
      procParentCache = parentOf;
      procParentCacheAt = DateTime.now();
      enumerateSource = '/proc';
      return ProcessTree(rootPid: supervisorPid, parentOf: parentOf);
    } on Object catch (e) {
      notes.add('/proc enumerate failed: $e');
      return null;
    }
  }

  Future<ProcessTree?> enumerateBounded() async {
    final left = remaining();
    if (left <= Duration.zero) {
      notes.add('enumerate skipped: budget exhausted');
      return null;
    }
    if (preferProcEnumerate && Platform.isLinux) {
      return enumerateLinuxProcSync();
    }
    try {
      final tree = await probe
          .enumerate(supervisorPid)
          .timeout(left, onTimeout: () => null);
      if (tree != null) {
        enumerateSource = 'ps';
        return tree;
      }
      notes.add('ps enumerate unavailable');
      if (Platform.isLinux) {
        preferProcEnumerate = true;
        return enumerateLinuxProcSync();
      }
      return null;
    } on TimeoutException {
      notes.add('enumerate timed out');
      if (Platform.isLinux) {
        preferProcEnumerate = true;
        return enumerateLinuxProcSync();
      }
      return null;
    } on Object catch (e) {
      notes.add('enumerate failed: $e');
      if (Platform.isLinux) {
        preferProcEnumerate = true;
        return enumerateLinuxProcSync();
      }
      return null;
    }
  }

  Future<bool?> adopteeAliveBounded(int pid) async {
    final left = remaining();
    if (left <= Duration.zero) {
      notes.add('liveness inspect skipped for $pid: budget exhausted');
      return null;
    }
    if (Platform.isLinux) {
      final state = linuxProcStateChar(pid);
      if (state == 'Z') {
        if (tryReapChildZombie(pid)) {
          totalReaped++;
          notes.add('reaped zombie adoptee $pid');
          return false;
        }
        notes.add('live zombie adoptee $pid awaiting reap');
        return true;
      }
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
    final adoptees = tree == null
        ? const <int>[]
        : directSubreaperAdoptees(tree, supervisorPid);
    await receipt('enumerate', inspectPids: adoptees);
    if (tree == null) {
      return SubreaperDrainResult(
        settled: false,
        verified: false,
        survivors: const [],
        notes: [...notes, 'process table unavailable during subreaper drain'],
      );
    }
    final descendants = directSubreaperAdoptees(tree, supervisorPid);
    final alive = <int>[];
    for (final pid in descendants) {
      if (remaining() <= Duration.zero) {
        notes.add('incomplete descendant liveness inspection');
        await receipt('liveness_budget', inspectPids: descendants, errors: notes);
        return SubreaperDrainResult(
          settled: false,
          verified: false,
          survivors: alive,
          notes: notes,
        );
      }
      final aliveState = await adopteeAliveBounded(pid);
      if (aliveState == null) {
        await receipt('liveness_incomplete', inspectPids: descendants, errors: notes);
        return SubreaperDrainResult(
          settled: false,
          verified: false,
          survivors: alive,
          notes: [...notes, 'incomplete descendant liveness inspection'],
        );
      }
      if (aliveState) alive.add(pid);
    }
    if (alive.isNotEmpty) {
      sawAliveAdoptee = true;
    }
    if (alive.isEmpty) {
      if (sawAliveAdoptee) {
        await receipt('settled_empty', inspectPids: descendants);
        return SubreaperDrainResult(
          settled: true,
          verified: true,
          survivors: const [],
          notes: notes,
        );
      }
      if (descendants.isEmpty) {
        emptyDescendantPolls++;
        if (emptyDescendantPolls >= 3) {
          await receipt('settled_no_adoptees', inspectPids: descendants);
          return SubreaperDrainResult(
            settled: true,
            verified: true,
            survivors: const [],
            notes: notes,
          );
        }
      } else {
        emptyDescendantPolls = 0;
      }
      if (remaining() > Duration.zero) {
        final delay = poll > remaining() ? remaining() : poll;
        if (delay <= Duration.zero) break;
        await Future<void>.delayed(delay);
        continue;
      }
      break;
    }
    await receipt('kill_pass', inspectPids: alive);
    for (final pid in alive.reversed) {
      if (remaining() <= Duration.zero) {
        notes.add('drain budget exhausted during kill pass');
        await receipt('kill_budget', inspectPids: alive, errors: notes);
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
    final reaped = reapAvailableChildZombies();
    if (reaped > 0) {
      totalReaped += reaped;
      notes.add('reaped $reaped zombie children after kill pass');
    }
    final delay = poll > remaining() ? remaining() : poll;
    if (delay <= Duration.zero) {
      notes.add('drain budget exhausted before poll delay');
      await receipt('poll_budget', inspectPids: alive, errors: notes);
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
  final finalAdoptees = tree == null
      ? const <int>[]
      : directSubreaperAdoptees(tree, supervisorPid);
  await receipt('final_enumerate', inspectPids: finalAdoptees);
  if (tree == null) {
    return SubreaperDrainResult(
      settled: false,
      verified: false,
      survivors: const [],
      notes: [...notes, 'final enumerate unavailable'],
    );
  }
  final survivors = <int>[];
  for (final pid in finalAdoptees) {
    if (remaining() <= Duration.zero) {
      notes.add('incomplete final liveness inspection');
      await receipt('final_liveness_budget', inspectPids: finalAdoptees);
      return SubreaperDrainResult(
        settled: false,
        verified: false,
        survivors: survivors,
        notes: notes,
      );
    }
    final aliveState = await adopteeAliveBounded(pid);
    if (aliveState == null) {
      await receipt('final_liveness_incomplete', inspectPids: finalAdoptees);
      return SubreaperDrainResult(
        settled: false,
        verified: false,
        survivors: survivors,
        notes: [...notes, 'incomplete final liveness inspection'],
      );
    }
    if (aliveState) survivors.add(pid);
  }
  totalReaped += reapAvailableChildZombies();
  if (survivors.isNotEmpty) {
    await receipt('survivors', inspectPids: survivors, errors: notes);
    return SubreaperDrainResult(
      settled: false,
      verified: false,
      survivors: survivors,
      notes: [...notes, 'survivors remain after drain budget'],
    );
  }
  await receipt('complete', inspectPids: finalAdoptees);
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
