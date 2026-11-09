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

/// Kills every live direct adoptee of [supervisorPid] (subreaper orphans).
Future<SubreaperDrainResult> drainSubreaperAdoptees({
  required int supervisorPid,
  ProcessTreeProbe probe = const HostProcessTreeProbe(),
  ProcessLiveness liveness = const HostProcessLiveness(),
  Duration budget = const Duration(seconds: 20),
  Duration poll = const Duration(milliseconds: 100),
  Duration killGrace = const Duration(milliseconds: 400),
  Future<void> Function(SubreaperDrainReceipt receipt)? onReceipt,
  LinuxProcStatReader procStatReader = const HostLinuxProcStatReader(),
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
  var totalReaped = 0;
  var emptyCompletePolls = 0;
  String? lastEnumerateReceiptKey;

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
      if (key == lastEnumerateReceiptKey && errors.isEmpty) return;
      lastEnumerateReceiptKey = key;
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

  void noteScan(LinuxProcParentMapScan scan) {
    if (scan.timedOut) {
      notes.add('proc scan: timed out before deadline');
    }
    for (final e in scan.errors.take(8)) {
      notes.add('proc scan: $e');
    }
  }

  Future<({ProcessTree? tree, LinuxProcParentMapScan? scan})>
      enumerateLinuxProcFresh() async {
    if (!Platform.isLinux) return (tree: null, scan: null);
    final left = remaining();
    if (left <= Duration.zero) {
      notes.add('proc enumerate skipped: budget exhausted');
      return (tree: null, scan: null);
    }
    final scan = await scanLinuxProcParentMap(
      deadline: DateTime.now().add(left),
      reader: procStatReader,
    );
    noteScan(scan);
    enumerateSource = '/proc';
    if (!scan.complete) {
      return (tree: null, scan: scan);
    }
    return (tree: scan.treeFor(supervisorPid), scan: scan);
  }

  Future<({ProcessTree? tree, LinuxProcParentMapScan? scan})>
      enumerateBounded() async {
    final left = remaining();
    if (left <= Duration.zero) {
      notes.add('enumerate skipped: budget exhausted');
      return (tree: null, scan: null);
    }
    if (preferProcEnumerate && Platform.isLinux) {
      return await enumerateLinuxProcFresh();
    }
    try {
      final tree = await probe
          .enumerate(supervisorPid)
          .timeout(left, onTimeout: () => null);
      if (tree != null) {
        enumerateSource = 'ps';
        return (tree: tree, scan: null);
      }
      notes.add('ps enumerate unavailable');
      if (Platform.isLinux) {
        preferProcEnumerate = true;
        return await enumerateLinuxProcFresh();
      }
      return (tree: null, scan: null);
    } on TimeoutException {
      notes.add('enumerate timed out');
      if (Platform.isLinux) {
        preferProcEnumerate = true;
        return await enumerateLinuxProcFresh();
      }
      return (tree: null, scan: null);
    } on Object catch (e) {
      notes.add('enumerate failed: $e');
      if (Platform.isLinux) {
        preferProcEnumerate = true;
        return await enumerateLinuxProcFresh();
      }
      return (tree: null, scan: null);
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

  Future<SubreaperDrainResult> verifiedDrainComplete(String phase) async {
    if (remaining() <= Duration.zero) {
      notes.add('verified blocked ($phase): budget exhausted');
      await receipt('verified_budget', errors: notes);
      return SubreaperDrainResult(
        settled: false,
        verified: false,
        survivors: const [],
        notes: notes,
      );
    }
    final fresh = await enumerateLinuxProcFresh();
    if (fresh.tree == null) {
      return SubreaperDrainResult(
        settled: false,
        verified: false,
        survivors: const [],
        notes: [...notes, 'verified blocked: incomplete proc scan'],
      );
    }
    var adoptees = directSubreaperAdoptees(fresh.tree!, supervisorPid);
    if (Platform.isLinux && remaining() > Duration.zero) {
      final confirm = await scanLinuxProcParentMap(
        deadline: DateTime.now().add(remaining()),
      );
      noteScan(confirm);
      if (!confirm.complete) {
        return SubreaperDrainResult(
          settled: false,
          verified: false,
          survivors: const [],
          notes: [...notes, 'verified blocked: host proc confirm incomplete'],
        );
      }
      final hostTree = confirm.treeFor(supervisorPid);
      if (hostTree == null) {
        return SubreaperDrainResult(
          settled: false,
          verified: false,
          survivors: const [],
          notes: [...notes, 'verified blocked: host proc confirm empty'],
        );
      }
      adoptees = {
        ...adoptees,
        ...directSubreaperAdoptees(hostTree, supervisorPid),
      }.toList();
    }
    await receipt(phase, inspectPids: adoptees, errors: fresh.scan?.errors ?? []);
    final survivors = <int>[];
    for (final pid in adoptees) {
      if (remaining() <= Duration.zero) {
        notes.add('verified blocked: final liveness budget');
        return SubreaperDrainResult(
          settled: false,
          verified: false,
          survivors: survivors,
          notes: notes,
        );
      }
      final alive = await adopteeAliveBounded(pid);
      if (alive == null) {
        return SubreaperDrainResult(
          settled: false,
          verified: false,
          survivors: survivors,
          notes: [...notes, 'verified blocked: liveness incomplete'],
        );
      }
      if (alive) survivors.add(pid);
    }
    totalReaped += reapAvailableChildZombies();
    if (survivors.isNotEmpty) {
      return SubreaperDrainResult(
        settled: false,
        verified: false,
        survivors: survivors,
        notes: [...notes, 'survivors after verified pass'],
      );
    }
    return SubreaperDrainResult(
      settled: true,
      verified: true,
      survivors: const [],
      notes: notes,
    );
  }

  while (remaining() > Duration.zero) {
    final enumerated = await enumerateBounded();
    final tree = enumerated.tree;
    final adoptees = tree == null
        ? const <int>[]
        : directSubreaperAdoptees(tree, supervisorPid);
    await receipt(
      'enumerate',
      inspectPids: adoptees,
      errors: enumerated.scan?.errors ?? const [],
    );
    if (tree == null) {
      return SubreaperDrainResult(
        settled: false,
        verified: false,
        survivors: const [],
        notes: [...notes, 'process table unavailable during subreaper drain'],
      );
    }
    final alive = <int>[];
    for (final pid in adoptees) {
      if (remaining() <= Duration.zero) {
        notes.add('incomplete descendant liveness inspection');
        await receipt('liveness_budget', inspectPids: adoptees, errors: notes);
        return SubreaperDrainResult(
          settled: false,
          verified: false,
          survivors: alive,
          notes: notes,
        );
      }
      final aliveState = await adopteeAliveBounded(pid);
      if (aliveState == null) {
        await receipt('liveness_incomplete', inspectPids: adoptees, errors: notes);
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
      emptyCompletePolls = 0;
    }
    if (alive.isEmpty) {
      if (sawAliveAdoptee) {
        return verifiedDrainComplete('settled_after_kill');
      }
      if (adoptees.isEmpty && enumerated.scan?.complete == true) {
        final confirm = await enumerateLinuxProcFresh();
        final confirmAdoptees = confirm.tree == null
            ? null
            : directSubreaperAdoptees(confirm.tree!, supervisorPid);
        if (confirm.tree != null &&
            confirm.scan?.complete == true &&
            confirmAdoptees != null &&
            confirmAdoptees.isEmpty) {
          emptyCompletePolls++;
          if (emptyCompletePolls >= 2) {
            break;
          }
        } else {
          emptyCompletePolls = 0;
        }
      } else {
        emptyCompletePolls = 0;
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

  return verifiedDrainComplete('final_complete');
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
