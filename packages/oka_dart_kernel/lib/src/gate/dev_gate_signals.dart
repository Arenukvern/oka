import 'dart:async';
import 'dart:io';

/// Coordinates one async cleanup under SIGTERM/SIGINT (no concurrent teardown).
final class DevGateSignalCoordinator {
  DevGateSignalCoordinator({required this.onSignal});

  final Future<void> Function() onSignal;
  bool _installed = false;
  bool _running = false;
  ProcessSignal _last = ProcessSignal.sigterm;

  void install() {
    if (_installed) return;
    _installed = true;
    ProcessSignal.sigterm.watch().listen((s) {
      _last = s;
      unawaited(_handle());
    });
    ProcessSignal.sigint.watch().listen((s) {
      _last = s;
      unawaited(_handle());
    });
  }

  Future<void> _handle({bool testMode = false}) async {
    if (_running) return;
    _running = true;
    await onSignal();
    if (!testMode) {
      exit(128 + _last.signalNumber);
    }
  }

  /// Test hook: run the same single-flight handler without exiting the VM.
  Future<void> invokeForTest(ProcessSignal signal) async {
    _last = signal;
    await _handle(testMode: true);
  }
}
