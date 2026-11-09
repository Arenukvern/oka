/// Relates [DevSessionDiscovery.pid] to a harness [Process.start] handle.
///
/// The discovery file records the **session owner** — the live `oka dev`
/// process that owns the control server and clears discovery on exit
/// (`dart:io` pid at `session.ready`). A spawn handle may differ when the
/// `oka` entrypoint is a shell wrapper or `dart pub global activate`
/// launcher that starts a child Dart VM. Consumers must not assert
/// `discovery.pid == spawn.pid`; use [verifyRunnerSessionSpawnBinding].
library;

import 'dart:io';

import 'package:oka_core/oka_core.dart';

import 'dev_session.dart';

/// How discovery `pid` relates to the harness spawn handle.
enum RunnerSessionSpawnBinding {
  /// Same live process.
  exact,

  /// Discovery pid is a descendant of the spawn handle (wrapper → session).
  spawnAncestorsSessionOwner,

  /// Discovery pid is an ancestor of the spawn handle (rare re-parenting).
  sessionOwnerAncestorsSpawn,

  /// No parent/child relationship in the live process table.
  unrelated,

  /// The process table could not be read (do not treat as proof of hijack).
  unknown,
}

/// Outcome of [verifyRunnerSessionSpawnBinding].
final class RunnerSessionSpawnBindingReport {
  const RunnerSessionSpawnBindingReport({
    required this.discoveryPid,
    required this.spawnPid,
    required this.binding,
  });

  final int discoveryPid;
  final int spawnPid;
  final RunnerSessionSpawnBinding binding;

  /// True when the discovery record plausibly belongs to this spawn tree.
  ///
  /// Prefer cooperative stop via [DevSessionDiscovery.controlPort]; the spawn
  /// handle remains the object waited on for exit even when [binding] is not
  /// [RunnerSessionSpawnBinding.exact].
  bool get isPlausibleOwnership => switch (binding) {
        RunnerSessionSpawnBinding.exact ||
        RunnerSessionSpawnBinding.spawnAncestorsSessionOwner ||
        RunnerSessionSpawnBinding.sessionOwnerAncestorsSpawn =>
          true,
        RunnerSessionSpawnBinding.unrelated ||
        RunnerSessionSpawnBinding.unknown =>
          false,
      };
}

/// Bounded ancestry check between discovery `pid` and [spawnHandle].pid.
Future<RunnerSessionSpawnBindingReport> verifyRunnerSessionSpawnBinding({
  required DevSessionDiscovery discovery,
  required Process spawnHandle,
  ProcessTreeProbe probe = const HostProcessTreeProbe(),
}) =>
    verifyRunnerSessionSpawnBindingPids(
      discoveryPid: discovery.pid,
      spawnPid: spawnHandle.pid,
      probe: probe,
    );

/// Same as [verifyRunnerSessionSpawnBinding] with explicit pids.
Future<RunnerSessionSpawnBindingReport> verifyRunnerSessionSpawnBindingPids({
  required int discoveryPid,
  required int spawnPid,
  ProcessTreeProbe probe = const HostProcessTreeProbe(),
}) async {
  if (discoveryPid <= 0 || spawnPid <= 0) {
    return RunnerSessionSpawnBindingReport(
      discoveryPid: discoveryPid,
      spawnPid: spawnPid,
      binding: RunnerSessionSpawnBinding.unknown,
    );
  }
  if (discoveryPid == spawnPid) {
    return RunnerSessionSpawnBindingReport(
      discoveryPid: discoveryPid,
      spawnPid: spawnPid,
      binding: RunnerSessionSpawnBinding.exact,
    );
  }
  final fromSpawn = await probe.enumerate(spawnPid);
  if (fromSpawn == null) {
    return RunnerSessionSpawnBindingReport(
      discoveryPid: discoveryPid,
      spawnPid: spawnPid,
      binding: RunnerSessionSpawnBinding.unknown,
    );
  }
  if (_isAncestorOf(fromSpawn.parentOf, spawnPid, discoveryPid)) {
    return RunnerSessionSpawnBindingReport(
      discoveryPid: discoveryPid,
      spawnPid: spawnPid,
      binding: RunnerSessionSpawnBinding.spawnAncestorsSessionOwner,
    );
  }
  final fromDiscovery = await probe.enumerate(discoveryPid);
  if (fromDiscovery == null) {
    return RunnerSessionSpawnBindingReport(
      discoveryPid: discoveryPid,
      spawnPid: spawnPid,
      binding: RunnerSessionSpawnBinding.unknown,
    );
  }
  if (_isAncestorOf(fromDiscovery.parentOf, discoveryPid, spawnPid)) {
    return RunnerSessionSpawnBindingReport(
      discoveryPid: discoveryPid,
      spawnPid: spawnPid,
      binding: RunnerSessionSpawnBinding.sessionOwnerAncestorsSpawn,
    );
  }
  return RunnerSessionSpawnBindingReport(
    discoveryPid: discoveryPid,
    spawnPid: spawnPid,
    binding: RunnerSessionSpawnBinding.unrelated,
  );
}

bool _isAncestorOf(Map<int, int> parentOf, int ancestor, int descendant) {
  var current = descendant;
  final seen = <int>{};
  while (parentOf.containsKey(current) && seen.add(current)) {
    final parent = parentOf[current]!;
    if (parent == ancestor) return true;
    current = parent;
  }
  return false;
}
