/// Application-owned convergence, without installing a resident daemon.
library;

import 'dart:async';

import 'package:resource_composition/resource_composition.dart';

import 'converge.dart';
import 'registry.dart';
import 'spec.dart';

/// Retain one instance per app/project scope. Loading plans never enables it.
/// Calls during an active pass join that pass; a later tick reads fresh plans.
final class AppSupervisorSession {
  AppSupervisorSession({
    required this.supervisor,
    required this.loadDesired,
    required this.factoryFor,
    this.evidence,
    this.onLog,
    this.onError,
    this.onReport,
    this.jobBudget = const Duration(minutes: 10),
  });

  final Supervisor supervisor;
  final Future<DesiredState> Function() loadDesired;
  final ProviderFactory Function(DesiredState desired) factoryFor;
  final EvidenceSink? evidence;
  final void Function(String id, LogTap log)? onLog;
  final void Function(Object error, StackTrace stack)? onError;
  final void Function(ConvergenceReport report)? onReport;
  final Duration jobBudget;
  final Map<String, (SupervisorRecord, ResourceProvider)> _owned = {};
  Future<ConvergenceReport>? _active;
  Cancellation? _cancellation;
  Timer? _timer;
  bool _closed = false;
  Future<List<StopReport>>? _closing;
  Future<List<StopReport>>? _stopping;

  bool get enabled => _timer != null;
  bool get running => _active != null;

  /// Enabling is explicit. Scheduling uses the supervisor's durable intervals.
  void enable({Duration pollInterval = const Duration(seconds: 5)}) {
    if (_closed) throw StateError('app supervisor session is closed');
    if (pollInterval <= Duration.zero) {
      throw ArgumentError.value(pollInterval, 'pollInterval');
    }
    _timer ??= Timer.periodic(pollInterval, (_) => _tick());
    _tick();
  }

  void _tick() {
    unawaited(
      converge().then<void>(
        (_) {},
        onError: (Object e, StackTrace s) {
          onError?.call(e, s);
        },
      ),
    );
  }

  /// Stops future scheduling. The running pass continues unless cancelled.
  void pause() {
    _timer?.cancel();
    _timer = null;
  }

  void cancel() => _cancellation?.cancel();

  Future<ConvergenceReport> converge() {
    if (_closed) return Future.error(StateError('app supervisor is closed'));
    if (_stopping != null) {
      return Future.error(StateError('app supervisor is stopping'));
    }
    final active = _active;
    if (active != null) return active;
    final cancellation = Cancellation();
    _cancellation = cancellation;
    final future = _converge(cancellation);
    _active = future;
    // Clear on both success and failure without creating an unhandled future.
    unawaited(
      future.then<void>(
        (_) {
          _active = null;
          _cancellation = null;
        },
        onError: (Object error, StackTrace stack) {
          _active = null;
          _cancellation = null;
        },
      ),
    );
    return future;
  }

  Future<ConvergenceReport> _converge(Cancellation cancellation) async {
    final desired = await loadDesired();
    final factory = factoryFor(desired);
    final report = await supervisor.converge(
      desired: desired,
      factory: factory,
      evidence: evidence,
      cancellation: cancellation,
      jobBudget: jobBudget,
      onLog: onLog,
      onStarted: (record, provider) {
        if (record.pid != null) {
          _owned[record.componentId] = (record, provider);
        }
      },
    );
    onReport?.call(report);
    return report;
  }

  /// Seals admission and joins cleanup. Changed/foreign generations survive.
  Future<List<StopReport>> close() => _closing ??= _close();

  Future<List<StopReport>> _close() {
    _closed = true;
    return stop();
  }

  /// Pauses dispatch, joins active cancellation, and stops session-owned work.
  /// Unlike close, the application may explicitly enable this session again.
  Future<List<StopReport>> stop() {
    final activeStop = _stopping;
    if (activeStop != null) return activeStop;
    final future = _stop();
    _stopping = future;
    unawaited(
      future.then<void>(
        (_) {
          _stopping = null;
        },
        onError: (Object error, StackTrace stack) {
          _stopping = null;
        },
      ),
    );
    return future;
  }

  Future<List<StopReport>> _stop() async {
    pause();
    cancel();
    try {
      await _active;
    } on Object {
      // Even a failed pass may have started a service before its failure.
    }
    final reports = <StopReport>[];
    for (final (record, provider) in _owned.values.toList().reversed) {
      final current = supervisor.registry.snapshot(
        supervisor.scope,
      )[record.componentId];
      if (current == null ||
          current.epoch != record.epoch ||
          current.pid != record.pid ||
          current.identityToken != record.identityToken ||
          current.killPolicy != KillPolicy.spawned) {
        continue;
      }
      try {
        final report = await provider.stop(
          ResourceRef(
            componentId: record.componentId,
            handle: record.handle ?? '',
            pid: record.pid,
            identityToken: record.identityToken,
          ),
          grace: const Duration(seconds: 3),
        );
        reports.add(report);
        if (report.stopped) _owned.remove(record.componentId);
      } on Object catch (error) {
        reports.add(
          StopReport(
            disposition: StopDisposition.unknown,
            message: 'stop failed: $error',
          ),
        );
      }
    }
    return reports;
  }
}
