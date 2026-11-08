import 'dart:async';
import 'dart:io';

import 'owned_dev_session.dart';

/// Exists before the first [Process.start]; SIGTERM during [OwnedDevSession.start]
/// must stop anything already spawned (not wait for [_activeSession]).
final class OwnedDevSessionStartController {
  OwnedDevSessionStartController({this._onBootstrapExtra});

  final void Function(OwnedDevSession session)? _onBootstrapExtra;
  Process? _spawnedRoot;
  OwnedDevSession? _session;
  var _abortRequested = false;

  bool get abortRequested => _abortRequested;

  // ignore: use_setters_to_change_properties
  void onProcessSpawned(Process proc) => _spawnedRoot = proc;

  /// Called as soon as streams are attached (before identity / ready).
  // ignore: use_setters_to_change_properties
  void onBootstrap(OwnedDevSession session) {
    _onBootstrapExtra?.call(session);
    _session = session;
  }

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
  // Bounded graceful stop inside the dedicated supervisor — never tear down
  // the supervision root before its drain ack (no stopProcessTree here).
    try {
      proc.kill();
    } on Object {
      return;
    }
    try {
      await proc.exitCode.timeout(quitGrace);
    } on TimeoutException {
      // Leave process running; caller must treat start as unverified.
    }
  }
}
