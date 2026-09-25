/// Reusable conformance assertions for managed session-state workflows.
library;

import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// A managed-session-state conformance assertion failed.
final class SessionStateConformanceException implements Exception {
  const SessionStateConformanceException(this.message);

  final String message;

  @override
  String toString() => 'Session-state conformance failed: $message';
}

/// Checks workflow validation and proves that each provider provision stage
/// starts only after its lease and reservation marker are durable.
///
/// This runs the workflow's provision stages, so callers should use an
/// isolated registry and a request whose planned resources are disposable test
/// fixtures. The returned lease is the completed acquisition.
Future<SessionStateLease> expectSessionStateProvisionConformance<H>({
  required SessionStateWorkflow<H> workflow,
  required SessionStateRequest request,
  required SessionStateRegistry registry,
  ProcessLiveness liveness = const HostProcessLiveness(),
}) async {
  final workflowIssues = workflow.validate();
  if (workflowIssues.isNotEmpty) {
    throw SessionStateConformanceException(
      'workflow "${workflow.id}" is invalid: ${workflowIssues.join('; ')}',
    );
  }
  if (workflow.provision.isEmpty) {
    throw SessionStateConformanceException(
      'workflow "${workflow.id}" has no provision stages; '
      'reserve-before-provision behavior was not exercised.',
    );
  }

  final probes = <_ReservationProbe<H>>[];
  final probedWorkflow = SessionStateWorkflow<H>(
    id: workflow.id,
    version: workflow.version,
    plan: workflow.plan,
    source: workflow.source,
    provision: [
      for (final step in workflow.provision)
        _ReservationProbe(step, registry, probes),
    ],
    inspectors: workflow.inspectors,
    cleanup: workflow.cleanup,
  );
  final lease = await SessionStateManager(
    registry: registry,
    liveness: liveness,
  ).acquire(probedWorkflow, request);

  if (probes.length != workflow.provision.length) {
    throw SessionStateConformanceException(
      'expected ${workflow.provision.length} provision-stage checks, '
      'observed ${probes.length}.',
    );
  }
  final persisted = await registry.read(lease.id);
  if (persisted == null ||
      persisted.phase != SessionStatePhase.ready ||
      persisted.generation < 2) {
    throw SessionStateConformanceException(
      'completed lease "${lease.id}" was not durably recorded as ready.',
    );
  }
  return lease;
}

/// Confirms that a workflow's busy/unknown provider observation prevents
/// explicit cleanup from disposing its lease.
///
/// The lease must be an isolated ephemeral acquisition in a scenario where
/// the workflow's inspector reports busy or unknown (or fails). The read-only
/// observation is checked before apply so this helper never applies cleanup
/// when the fail-closed branch was not exercised.
Future<SessionStateReconcileReport> expectSessionStateFailClosed({
  required SessionStateReconciler reconciler,
  required SessionStateRegistry registry,
  required String leaseId,
}) async {
  final observation = await reconciler.inspectLease(leaseId: leaseId);
  if (observation.issues.isNotEmpty) {
    throw const SessionStateConformanceException(
      'cannot exercise inspector conformance while the registry has issues.',
    );
  }
  if (observation.entries.length != 1) {
    throw SessionStateConformanceException(
      'lease "$leaseId" was not available for read-only inspection.',
    );
  }
  final observedEntry = observation.entries.single;
  final workflow = reconciler.workflows.where(
    (final item) =>
        item.id == observedEntry.lease.workflowId &&
        item.version == observedEntry.lease.workflowVersion,
  );
  final providerInspectorIds = workflow.isEmpty
      ? const <String>{}
      : workflow.single.inspectors
            .map((final inspector) => inspector.id)
            .toSet();
  final hasFailClosedProviderFinding = observedEntry.findings.any(
    (final finding) =>
        providerInspectorIds.contains(finding.inspectorId) &&
        finding.use != SessionStateUse.unused,
  );
  final inspectorFailedClosed = observedEntry.findings.any(
    (final finding) =>
        finding.inspectorId == 'oka.workflow-inspection' &&
        finding.reason.startsWith('provider observation failed:'),
  );
  if (!hasFailClosedProviderFinding && !inspectorFailedClosed) {
    throw SessionStateConformanceException(
      'lease "$leaseId" did not produce busy/unknown provider-inspector '
      'evidence or an inspector failure; '
      'the fail-closed branch was not exercised.',
    );
  }

  final report = await reconciler.close(leaseId: leaseId, apply: true);
  final entry = report.entries.where((final item) => item.lease.id == leaseId);
  final persisted = await registry.read(leaseId);
  if (entry.length != 1 ||
      entry.single.disposition != SessionStateDisposition.retained ||
      persisted == null) {
    throw SessionStateConformanceException(
      'busy or unknown provider evidence did not retain lease "$leaseId".',
    );
  }
  return report;
}

/// Acquires a caller-owned borrowed resource and proves explicit cleanup
/// retains both its lease and (for directory resources) the caller's
/// directory, independent of its retention duration.
Future<SessionStateLease> expectSessionStateBorrowedRetention<H>({
  required SessionStateWorkflow<H> workflow,
  required SessionStateRequest request,
  required SessionStateRegistry registry,
  ProcessLiveness liveness = const HostProcessLiveness(),
}) async {
  final workflowIssues = workflow.validate();
  if (workflowIssues.isNotEmpty) {
    throw SessionStateConformanceException(
      'workflow "${workflow.id}" is invalid: ${workflowIssues.join('; ')}',
    );
  }
  final plan = workflow.plan.plan(request);
  final planIssues = plan.validate();
  if (planIssues.isNotEmpty) {
    throw SessionStateConformanceException(
      'workflow "${workflow.id}" produced an invalid borrowed plan: '
      '${planIssues.join('; ')}',
    );
  }
  if (plan.ownership != SessionStateOwnership.caller ||
      plan.acquisitionMode != SessionStateAcquisitionMode.borrowed) {
    throw const SessionStateConformanceException(
      'borrowed-retention scenario must plan caller ownership and borrowed '
      'acquisition.',
    );
  }

  final lease = await SessionStateManager(
    registry: registry,
    liveness: liveness,
  ).acquire(workflow, request);
  final reconciler = SessionStateReconciler(
    registry: registry,
    workflows: [workflow],
    liveness: liveness,
  );
  final report = await reconciler.close(leaseId: lease.id, apply: true);
  final entry = report.entries.where((final item) => item.lease.id == lease.id);
  if (entry.length != 1 ||
      entry.single.disposition != SessionStateDisposition.retained ||
      await registry.read(lease.id) == null) {
    throw SessionStateConformanceException(
      'caller-owned borrowed lease "${lease.id}" was not retained.',
    );
  }
  if (plan.resourceKind == SessionStateResourceKind.directory) {
    final resource = Directory(p.join(plan.rootPath, plan.relativePath));
    if (await FileSystemEntity.type(resource.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw SessionStateConformanceException(
        'caller-owned directory "${resource.path}" was removed or replaced.',
      );
    }
  }
  return lease;
}

/// Returns registry issues, failing if the snapshot silently hides invalid
/// or future-schema records.
Future<List<SessionStateRegistryIssue>> expectSessionStateRegistryIssues(
  final SessionStateRegistry registry,
) async {
  final snapshot = await registry.inspect();
  if (snapshot.issues.isEmpty) {
    throw const SessionStateConformanceException(
      'expected the registry snapshot to report at least one issue.',
    );
  }
  return snapshot.issues;
}

final class _ReservationProbe<H> implements SessionStateProvisionStep<H> {
  _ReservationProbe(this.delegate, this.registry, this.probes);

  final SessionStateProvisionStep<H> delegate;
  final SessionStateRegistry registry;
  final List<_ReservationProbe<H>> probes;

  @override
  String get id => delegate.id;

  @override
  Set<Artifact<Object>> get requires => delegate.requires;

  @override
  Set<Artifact<Object>> get provides => delegate.provides;

  @override
  Future<void> run(final SessionStateContext<H> context) async {
    final persisted = await registry.read(context.lease.id);
    if (persisted == null ||
        persisted.phase != SessionStatePhase.provisioning ||
        persisted.generation < 1 ||
        context.lease.id != persisted.id) {
      throw SessionStateConformanceException(
        'provision stage "$id" started without a durable provisioning lease.',
      );
    }

    if (persisted.ownership == SessionStateOwnership.oka &&
        persisted.resourceKind == SessionStateResourceKind.directory) {
      final marker = File(persisted.reservationMarkerPath);
      if (!await marker.exists()) {
        throw SessionStateConformanceException(
          'provision stage "$id" started before its reservation marker '
          'was durable.',
        );
      }
      final markerData = jsonDecode(await marker.readAsString());
      if (markerData is! Map ||
          markerData['id'] != persisted.id ||
          markerData['nonce'] != persisted.markerNonce) {
        throw SessionStateConformanceException(
          'provision stage "$id" observed a mismatched reservation marker.',
        );
      }
    }
    probes.add(this);
    await delegate.run(context);
  }
}
