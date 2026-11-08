import 'dart:io';

import 'package:oka_core/oka_core.dart';

import 'owned_dev_session.dart';

/// Exists before the first [Process.start]; SIGTERM during [OwnedDevSession.start]
/// must stop anything already spawned (not wait for [_activeSession]).
final class OwnedDevSessionStartController {
  OwnedDevSessionStartController({
    this.treeProbe = const HostProcessTreeProbe(),
    this.liveness = const HostProcessLiveness(),
  });

  final ProcessTreeProbe treeProbe;
  final ProcessLiveness liveness;
  Process? _spawnedRoot;
  OwnedDevSession? _session;
  var _abortRequested = false;

  bool get abortRequested => _abortRequested;

  // ignore: use_setters_to_change_properties
  void onProcessSpawned(Process proc) => _spawnedRoot = proc;

  // ignore: use_setters_to_change_properties
  void onSessionReady(OwnedDevSession session) => _session = session;

  Future<void> requestAbort({
    Duration quitGrace = const Duration(seconds: 5),
  }) async {
    _abortRequested = true;
    final session = _session;
    if (session != null) {
      await session.teardown(quitGrace: quitGrace);
      return;
    }
    final proc = _spawnedRoot;
    if (proc == null || proc.pid <= 0) return;
    final stop = await stopProcessTree(
      probe: treeProbe,
      liveness: liveness,
      rootPid: proc.pid,
    );
    if (!stop.stopped || stop.survivors.isNotEmpty) {
      await liveness.kill(proc.pid, grace: const Duration(milliseconds: 500));
    }
  }
}
