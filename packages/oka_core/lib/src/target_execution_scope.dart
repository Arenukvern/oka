import 'dart:async';
import 'dart:io';

import 'config/build_context.dart';
import 'pipeline/pipeline.dart';
import 'process_teardown.dart';

typedef SignalStream = Stream<ProcessSignal> Function(ProcessSignal signal);
typedef ProcessExit = void Function(int code);

/// Owns one target's forward execution, signal subscriptions and teardown.
final class TargetExecutionScope {
  TargetExecutionScope({
    required this.teardownSteps,
    required this.ctx,
    required this.state,
    this.write,
    SignalStream? watchSignal,
    ProcessExit? exitProcess,
  }) : _watchSignal = watchSignal ?? ((signal) => signal.watch()),
       _exitProcess = exitProcess ?? exit;

  final List<BuildStep> teardownSteps;
  final BuildContext ctx;
  final PipelineState state;
  final void Function(String line)? write;
  final SignalStream _watchSignal;
  final ProcessExit _exitProcess;
  final List<StreamSubscription<ProcessSignal>> _subscriptions = [];
  Future<TeardownOutcome>? _teardown;
  bool _exitIssued = false;
  ProcessSignal? _pendingSignal;

  /// Cooperative cancellation at a pipeline step boundary. The current step
  /// must return its acquired handles before teardown can safely consume them.
  bool get cancellationRequested => _pendingSignal != null;

  /// Installs handlers before [forward], tears down exactly once, and always
  /// disposes the handlers. A forward error is rethrown unchanged.
  Future<StepResult> run(Future<StepResult> Function() forward) async {
    _installHandlers();
    try {
      return await forward();
    } finally {
      await teardown();
      for (final subscription in _subscriptions) {
        try {
          await subscription.cancel();
        } on Object {
          // Handler disposal must not replace the forward result or error.
        }
      }
      _subscriptions.clear();
      final pendingSignal = _pendingSignal;
      if (pendingSignal != null && !_exitIssued) {
        _exitIssued = true;
        try {
          _exitProcess(pendingSignal == ProcessSignal.sigint ? 130 : 143);
        } on Object {
          // A test/embedder exit hook must not replace the forward error.
        }
      }
    }
  }

  Future<TeardownOutcome> teardown() => _teardown ??= runTeardownSteps(
    teardownSteps,
    ctx: ctx,
    state: state,
    write: write,
  );

  void _installHandlers() {
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      try {
        final subscription = _watchSignal(signal).listen((received) {
          // Pipeline steps have no cancellation contract. Record the first
          // signal and let forward work reach its acquisition boundary; the
          // finally path then tears down every produced handle.
          _pendingSignal ??= received;
        });
        _subscriptions.add(subscription);
      } on Object {
        // Signal watching is unavailable on some hosts. Final teardown still
        // runs and remains the portable guarantee.
      }
    }
  }
}
