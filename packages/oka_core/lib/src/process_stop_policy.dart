import 'dart:async';

import 'process_lease.dart';
import 'process_lease_registry.dart';
import 'process_liveness.dart';

enum ProcessStopDisposition { stopped, staleRecord, refused, failed }

final class ProcessStopDecision {
  const ProcessStopDecision(this.disposition, {this.message});

  final ProcessStopDisposition disposition;
  final String? message;
  bool get ok =>
      disposition == ProcessStopDisposition.stopped ||
      disposition == ProcessStopDisposition.staleRecord;
}

typedef GracefulLeaseStop = Future<bool> Function(ProcessLease lease);
typedef VerifySemanticStop = Future<bool?> Function(ProcessLease lease);

/// Shared identity, ownership, verification and lease-retention policy.
/// Platform adapters provide only the graceful operation and, for pid-less
/// leases, a semantic verification probe.
final class ProcessStopPolicy {
  const ProcessStopPolicy({
    required this.registry,
    required this.liveness,
    this.verifyGrace = const Duration(seconds: 5),
    this.pollInterval = const Duration(milliseconds: 200),
  });

  final ProcessLeaseRegistry registry;
  final ProcessLiveness liveness;
  final Duration verifyGrace;
  final Duration pollInterval;

  Future<ProcessStopDecision> stop(
    ProcessLease lease, {
    required bool force,
    required GracefulLeaseStop gracefulStop,
    VerifySemanticStop? verifySemanticStop,
  }) async {
    try {
      return await _stop(
        lease,
        force: force,
        gracefulStop: gracefulStop,
        verifySemanticStop: verifySemanticStop,
      );
    } on Object catch (error) {
      return ProcessStopDecision(
        ProcessStopDisposition.failed,
        message: "Lease '${lease.id}' stop failed: $error; lease retained.",
      );
    }
  }

  Future<ProcessStopDecision> _stop(
    ProcessLease lease, {
    required bool force,
    required GracefulLeaseStop gracefulStop,
    VerifySemanticStop? verifySemanticStop,
  }) async {
    if (lease.ownership == LeaseOwnership.borrowed && !force) {
      return ProcessStopDecision(
        ProcessStopDisposition.refused,
        message:
            "Lease '${lease.id}' is borrowed; re-run with --force to stop it.",
      );
    }

    if (lease.pid <= 0) {
      if (lease.stopHint.args.isEmpty) {
        return ProcessStopDecision(
          ProcessStopDisposition.refused,
          message: "Lease '${lease.id}' has no pid or safe stop hint.",
        );
      }
      if (!await gracefulStop(lease)) {
        return ProcessStopDecision(
          ProcessStopDisposition.failed,
          message: "Lease '${lease.id}' semantic stop failed; lease retained.",
        );
      }
      final verified = await verifySemanticStop?.call(lease);
      if (verified != true) {
        return ProcessStopDecision(
          ProcessStopDisposition.failed,
          message:
              "Lease '${lease.id}' semantic stop could not be verified; lease retained.",
        );
      }
      await registry.delete(lease.id);
      return const ProcessStopDecision(ProcessStopDisposition.stopped);
    }

    final verdict = await registry.checkLiveness(lease);
    if (verdict == LeaseLiveness.deadPid ||
        verdict == LeaseLiveness.reusedPid) {
      await registry.delete(lease.id);
      return const ProcessStopDecision(ProcessStopDisposition.staleRecord);
    }
    if (verdict == LeaseLiveness.unknown) {
      return ProcessStopDecision(
        ProcessStopDisposition.refused,
        message:
            "Lease '${lease.id}' identity could not be verified "
            '(report-never-guess); lease retained.',
      );
    }

    await gracefulStop(lease);
    var stopped = await _waitUntilStopped(lease.pid);
    if (!stopped) {
      // The pid may have been recycled while the graceful operation was
      // pending. Re-check identity at the last possible moment before force.
      final beforeForce = await registry.checkLiveness(lease);
      if (beforeForce == LeaseLiveness.deadPid ||
          beforeForce == LeaseLiveness.reusedPid) {
        await registry.delete(lease.id);
        return const ProcessStopDecision(ProcessStopDisposition.staleRecord);
      }
      if (beforeForce != LeaseLiveness.live) {
        return ProcessStopDecision(
          ProcessStopDisposition.failed,
          message:
              "Lease '${lease.id}' identity became unverifiable before "
              'force; lease retained.',
        );
      }
      final forceAccepted = await liveness.kill(lease.pid, grace: verifyGrace);
      stopped = forceAccepted && await _isStopped(lease.pid) == true;
    }
    if (!stopped) {
      return ProcessStopDecision(
        ProcessStopDisposition.failed,
        message:
            "Lease '${lease.id}' is still alive or its stop could not "
            'be verified; lease retained.',
      );
    }
    await registry.delete(lease.id);
    return const ProcessStopDecision(ProcessStopDisposition.stopped);
  }

  Future<bool> _waitUntilStopped(int pid) async {
    final deadline = DateTime.now().add(verifyGrace);
    while (true) {
      final stopped = await _isStopped(pid);
      if (stopped == true) return true;
      if (stopped == null || !DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<bool?> _isStopped(int pid) async {
    try {
      return !await liveness.isAlive(pid);
    } on Object {
      return null;
    }
  }
}
