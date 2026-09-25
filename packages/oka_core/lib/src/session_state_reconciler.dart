/// Dry-run-first inspection and conservative cleanup of orphaned state.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'process_liveness.dart';
import 'session_state.dart';
import 'session_state_registry.dart';

/// Classification for a session-state lease.
enum SessionStateDisposition { eligible, retained, disposed, forgotten, error }

/// Explainable result for one lease.
final class SessionStateReconcileEntry {
  const SessionStateReconcileEntry({
    required this.lease,
    required this.disposition,
    required this.reason,
    this.findings = const [],
    this.resourceMissing = false,
  });

  final SessionStateLease lease;
  final SessionStateDisposition disposition;
  final String reason;
  final List<SessionStateFinding> findings;
  final bool resourceMissing;

  Map<String, Object?> toJson() => {
    'lease': lease.toJson(),
    'disposition': disposition.name,
    'reason': reason,
    'findings': findings.map((final finding) => finding.toJson()).toList(),
    'resource_missing': resourceMissing,
  };

  String toLine() =>
      '${lease.id}  ${lease.workflowId}@${lease.workflowVersion}  '
      '${lease.retention.label}/${lease.ownership.label}  '
      '${disposition.name}: $reason';
}

/// Full reconcile report, including registry parse issues.
final class SessionStateReconcileReport {
  const SessionStateReconcileReport({
    required this.entries,
    required this.issues,
    required this.applied,
  });

  final List<SessionStateReconcileEntry> entries;
  final List<SessionStateRegistryIssue> issues;
  final bool applied;

  int get eligibleCount => entries
      .where(
        (final entry) => entry.disposition == SessionStateDisposition.eligible,
      )
      .length;

  int get retainedCount => entries
      .where(
        (final entry) => entry.disposition == SessionStateDisposition.retained,
      )
      .length;

  int get forgottenCount => entries
      .where(
        (final entry) => entry.disposition == SessionStateDisposition.forgotten,
      )
      .length;

  Map<String, Object?> toJson() => {
    'schema_version': 'oka.session-state.reconcile.v1',
    'applied': applied,
    'summary': {
      'leases': entries.length,
      'eligible': eligibleCount,
      'retained': retainedCount,
      'forgotten': forgottenCount,
      'registry_issues': issues.length,
    },
    'entries': entries.map((final entry) => entry.toJson()).toList(),
    'issues': issues.map((final issue) => issue.toJson()).toList(),
  };
}

/// Reconciles only when an explicit workflow with the exact recorded version
/// is composed. Unknown providers and any inconclusive evidence are retained.
final class SessionStateReconciler {
  SessionStateReconciler({
    required this.registry,
    required List<SessionStateWorkflow<dynamic>> workflows,
    this.liveness = const HostProcessLiveness(),
  }) : workflows = List.unmodifiable(workflows) {
    final seen = <(String, int)>{};
    for (final workflow in this.workflows) {
      if (!seen.add((workflow.id, workflow.version))) {
        throw ArgumentError(
          'Session-state workflow "${workflow.id}" version '
          '${workflow.version} is duplicated in this composition.',
        );
      }
      final issues = workflow.validate();
      if (issues.isNotEmpty) {
        throw ArgumentError(
          'Invalid session-state workflow "${workflow.id}": '
          '${issues.join('; ')}',
        );
      }
    }
  }

  /// Failed cleanup stays retryable for a bounded number of automatic passes;
  /// afterward an operator must explicitly close/retry the lease.
  static const maxCleanupAttempts = 5;

  final SessionStateRegistry registry;
  final List<SessionStateWorkflow<dynamic>> workflows;
  final ProcessLiveness liveness;

  Future<SessionStateReconcileReport> reconcile({bool apply = false}) async {
    final snapshot = await registry.inspect();
    final entries = <SessionStateReconcileEntry>[];
    for (final lease in snapshot.leases) {
      final preview = await _inspectLease(lease);
      if (apply &&
          snapshot.issues.isEmpty &&
          preview.disposition == SessionStateDisposition.eligible) {
        entries.add(await _applyLease(lease));
      } else {
        entries.add(preview);
      }
    }
    return SessionStateReconcileReport(
      entries: List.unmodifiable(entries),
      issues: snapshot.issues,
      applied: apply && snapshot.issues.isEmpty,
    );
  }

  /// Produces a read-only, lease-scoped diagnostic without applying retention
  /// or liveness gates that would otherwise hide provider observations.
  Future<SessionStateReconcileReport> inspectLease({
    required String leaseId,
  }) async {
    final snapshot = await registry.inspect();
    final matches = snapshot.leases.where((final lease) => lease.id == leaseId);
    final entries = matches.isEmpty
        ? const <SessionStateReconcileEntry>[]
        : [await _observeLease(matches.single)];
    return SessionStateReconcileReport(
      entries: entries,
      issues: snapshot.issues,
      applied: false,
    );
  }

  /// Reconciles one selected lease with the automatic-cleanup safety policy.
  ///
  /// Unlike [close], this never bypasses retention or host/process proofs.
  Future<SessionStateReconcileReport> reconcileLease({
    required String leaseId,
    bool apply = false,
  }) async {
    final snapshot = await registry.inspect();
    final matches = snapshot.leases.where((final lease) => lease.id == leaseId);
    if (matches.isEmpty) {
      return SessionStateReconcileReport(
        entries: const [],
        issues: snapshot.issues,
        applied: false,
      );
    }
    final lease = matches.single;
    final preview = await _inspectLease(lease);
    final entry =
        apply &&
            snapshot.issues.isEmpty &&
            preview.disposition == SessionStateDisposition.eligible
        ? await _applyLease(lease)
        : preview;
    return SessionStateReconcileReport(
      entries: [entry],
      issues: snapshot.issues,
      applied: apply && snapshot.issues.isEmpty,
    );
  }

  /// Explicitly closes a named lease. Persistent/session retention is never
  /// eligible for automatic reconciliation, but can be closed by the owner
  /// after the same fresh ownership and inactivity checks pass.
  Future<SessionStateReconcileReport> close({
    required String leaseId,
    bool apply = false,
  }) async {
    final snapshot = await registry.inspect();
    final matches = snapshot.leases.where((final item) => item.id == leaseId);
    if (matches.isEmpty) {
      return SessionStateReconcileReport(
        entries: const [],
        issues: snapshot.issues,
        applied: false,
      );
    }
    final lease = matches.single;
    final preview = await _inspectLease(lease, explicitClose: true);
    final entry =
        apply &&
            snapshot.issues.isEmpty &&
            preview.disposition == SessionStateDisposition.eligible
        ? await _applyLease(lease, explicitClose: true)
        : preview;
    return SessionStateReconcileReport(
      entries: [entry],
      issues: snapshot.issues,
      applied: apply && snapshot.issues.isEmpty,
    );
  }

  /// Removes only a lease record after an explicit opt-in and affirmative
  /// proof that its local directory resource is absent. No resource data or
  /// reservation marker is touched.
  Future<SessionStateReconcileReport> forget({
    required String leaseId,
    bool apply = false,
  }) async {
    final snapshot = await registry.inspect();
    final matches = snapshot.leases.where((final item) => item.id == leaseId);
    if (matches.isEmpty) {
      return SessionStateReconcileReport(
        entries: const [],
        issues: snapshot.issues,
        applied: false,
      );
    }
    final lease = matches.single;
    final preview = await _inspectForget(lease);
    final entry =
        apply &&
            snapshot.issues.isEmpty &&
            preview.disposition == SessionStateDisposition.eligible
        ? await _forgetLease(lease)
        : preview;
    return SessionStateReconcileReport(
      entries: [entry],
      issues: snapshot.issues,
      applied: apply && snapshot.issues.isEmpty,
    );
  }

  Future<SessionStateReconcileEntry> _inspectLease(
    final SessionStateLease lease, {
    bool explicitClose = false,
  }) async {
    if (lease.phase == SessionStatePhase.disposed) {
      return SessionStateReconcileEntry(
        lease: lease,
        disposition: SessionStateDisposition.eligible,
        reason: 'disposal was confirmed; remove the completed registry record.',
      );
    }
    if (lease.phase == SessionStatePhase.quarantined && !explicitClose) {
      return _retain(
        lease,
        'cleanup is quarantined after ${lease.attemptCount} failed attempt(s); '
        'use `oka session-state close ${lease.id} --apply` to retry explicitly.',
      );
    }
    if (lease.retention != SessionStateRetention.ephemeral && !explicitClose) {
      return _retain(lease, 'retention is ${lease.retention.label}.');
    }
    if (lease.namespace != SessionStateNamespace.project) {
      return _retain(
        lease,
        'host-scoped resources need a provider-wide in-use proof.',
      );
    }
    if (lease.ownership != SessionStateOwnership.oka ||
        lease.acquisitionMode == SessionStateAcquisitionMode.borrowed) {
      return _retain(lease, 'resource is not positively Oka-owned.');
    }
    if (lease.resourceKind != SessionStateResourceKind.directory) {
      return _retain(lease, 'opaque resources are not auto-disposed.');
    }
    if (Platform.isWindows) {
      return _retain(
        lease,
        'Windows cleanup is report-only until path reparse-point and '
        'quarantine behavior pass real-host conformance tests.',
      );
    }
    if (lease.phase == SessionStatePhase.reserved ||
        lease.phase == SessionStatePhase.provisioning) {
      // Provision may have created a partial resource; it still goes through
      // the exact same ownership and active-use checks below.
    } else if (lease.phase != SessionStatePhase.ready &&
        lease.phase != SessionStatePhase.partial &&
        lease.phase != SessionStatePhase.disposing &&
        lease.phase != SessionStatePhase.quarantined) {
      return _retain(lease, 'lifecycle phase is not recoverable.');
    }

    final SessionStateHostIdentity host;
    try {
      host = await registry.hostIdentity(create: false);
    } on Object catch (error) {
      return _retain(lease, 'host identity could not be verified: $error');
    }
    if (!host.canProveSameBoot ||
        lease.hostId != host.hostId ||
        (lease.bootId != host.bootId && !explicitClose)) {
      return _retain(lease, 'host or boot identity does not match.');
    }
    final workflow = _workflowFor(lease);
    if (workflow == null) {
      return _retain(
        lease,
        'workflow ${lease.workflowId}@${lease.workflowVersion} is unavailable.',
      );
    }
    final workflowIssues = workflow.validate();
    if (workflowIssues.isNotEmpty) {
      return _retain(
        lease,
        'workflow composition is invalid: ${workflowIssues.join('; ')}',
      );
    }

    final unmaterializedReservation =
        (lease.phase == SessionStatePhase.reserved ||
            lease.phase == SessionStatePhase.partial)
        ? await _checkUnmaterializedReservation(lease)
        : null;
    final rootCheck =
        unmaterializedReservation ?? await _checkRootAndMarker(lease);
    if (rootCheck.finding.use != SessionStateUse.unused) {
      return SessionStateReconcileEntry(
        lease: lease,
        disposition: SessionStateDisposition.retained,
        reason: rootCheck.finding.reason,
        findings: [rootCheck.finding],
      );
    }

    // Even an explicit close after a boot change must inspect process identity.
    // Boot metadata can change on sleep/clock adjustment on some hosts; it is
    // not positive proof that every recorded process is gone.
    final ownerState = await _processState(lease.ownerPid, lease.ownerPidToken);
    if (ownerState != _ProcessState.stopped) {
      return _retain(
        lease,
        ownerState == _ProcessState.running
            ? 'the owning Oka process is still running.'
            : 'owner process identity is unknown.',
      );
    }
    if (lease.requiresProcessSnapshot && !lease.hasCompleteProcessSnapshot) {
      return _retain(
        lease,
        'a process was expected, but no durable associated-process identity '
        'snapshot exists.',
      );
    }
    if (lease.processPid != null && lease.processPid! > 0) {
      final processState = await _processState(
        lease.processPid!,
        lease.processPidToken,
      );
      if (processState != _ProcessState.stopped) {
        return _retain(
          lease,
          processState == _ProcessState.running
              ? 'the associated process is still running.'
              : 'associated process identity is unknown.',
        );
      }
    }

    if (!rootCheck.exists) {
      return SessionStateReconcileEntry(
        lease: lease,
        disposition: SessionStateDisposition.eligible,
        reason: rootCheck.finding.reason,
        findings: [rootCheck.finding],
        resourceMissing: true,
      );
    }

    final SessionStateWorkflowSession session;
    try {
      session = await workflow.restoreSession(lease);
    } on Object catch (error) {
      return _retain(
        lease,
        'provider could not restore its typed handle: $error',
      );
    }
    final List<SessionStateFinding> findings;
    try {
      findings = await session.inspect(lease);
    } on Object catch (error) {
      return SessionStateReconcileEntry(
        lease: lease,
        disposition: SessionStateDisposition.retained,
        reason: 'provider inspection failed; state was retained: $error',
        findings: [
          const SessionStateFinding(
            inspectorId: 'oka.workflow-inspection',
            use: SessionStateUse.unknown,
            reason:
                'an inspector failed before confirming the resource unused.',
          ),
        ],
      );
    }
    for (final finding in findings) {
      if (finding.use != SessionStateUse.unused) {
        return SessionStateReconcileEntry(
          lease: lease,
          disposition: SessionStateDisposition.retained,
          reason: '${finding.inspectorId}: ${finding.reason}',
          findings: findings,
        );
      }
    }
    return SessionStateReconcileEntry(
      lease: lease,
      disposition: SessionStateDisposition.eligible,
      reason: lease.quarantineRelativePath == null
          ? 'all ownership, host, process and provider checks passed.'
          : 'quarantined deletion can resume; all safety checks passed.',
      findings: List.unmodifiable(findings),
    );
  }

  Future<SessionStateReconcileEntry> _inspectForget(
    final SessionStateLease lease,
  ) async {
    if (lease.resourceKind != SessionStateResourceKind.directory) {
      return _retain(
        lease,
        'the opaque resource cannot be proven absent; its record was retained.',
      );
    }
    final rootPath = p.normalize(p.absolute(lease.rootPath));
    final rootType = await FileSystemEntity.type(rootPath, followLinks: false);
    if (rootType == FileSystemEntityType.notFound) {
      return SessionStateReconcileEntry(
        lease: lease,
        disposition: SessionStateDisposition.eligible,
        reason:
            'the resource root is unavailable; forgetting removes only the '
            'lease record and cannot remove data that may still exist elsewhere.',
      );
    }
    if (rootType != FileSystemEntityType.directory ||
        await _hasLinkedAncestor(rootPath)) {
      return _retain(
        lease,
        'the resource root is not a safe real directory; the record was retained.',
      );
    }
    final canonicalRoot = p.normalize(
      await Directory(rootPath).resolveSymbolicLinks(),
    );
    if (canonicalRoot != rootPath) {
      return _retain(
        lease,
        'the resource root no longer resolves to its recorded path.',
      );
    }
    if (lease.relativePath.isEmpty ||
        lease.relativePath.contains(r'\') ||
        p.posix.isAbsolute(lease.relativePath) ||
        lease.relativePath.split('/').contains('..')) {
      return _retain(lease, 'the recorded resource path is unsafe.');
    }
    final resourcePath = p.normalize(p.join(rootPath, lease.relativePath));
    if (!p.isWithin(rootPath, resourcePath) ||
        await _hasLinkedPath(rootPath, resourcePath)) {
      return _retain(
        lease,
        'the recorded resource path is outside its root or uses a symbolic link.',
      );
    }
    final resourceType = await FileSystemEntity.type(
      resourcePath,
      followLinks: false,
    );
    if (resourceType != FileSystemEntityType.notFound) {
      return _retain(
        lease,
        'the resource still exists; close it safely or move it manually before '
        'forgetting its record.',
      );
    }
    return SessionStateReconcileEntry(
      lease: lease,
      disposition: SessionStateDisposition.eligible,
      reason:
          'the resource is absent; forgetting removes only its lease record '
          'and leaves any reservation marker untouched.',
      resourceMissing: true,
    );
  }

  Future<SessionStateReconcileEntry> _forgetLease(
    final SessionStateLease snapshotLease,
  ) async {
    try {
      return await registry.withResourceLock(
        '${snapshotLease.namespace.label}:${snapshotLease.logicalResourceKey}',
        () async {
          final snapshot = await registry.inspect();
          if (snapshot.issues.isNotEmpty) {
            return _retain(
              snapshotLease,
              'registry contains ${snapshot.issues.length} issue(s); '
              'no record was removed.',
            );
          }
          final current = await registry.read(snapshotLease.id);
          if (current == null) {
            return SessionStateReconcileEntry(
              lease: snapshotLease,
              disposition: SessionStateDisposition.forgotten,
              reason: 'record was already removed by another operation.',
              resourceMissing: true,
            );
          }
          if (current.generation != snapshotLease.generation) {
            return _retain(current, 'record changed during inspection; retry.');
          }
          final rechecked = await _inspectForget(current);
          if (rechecked.disposition != SessionStateDisposition.eligible) {
            return rechecked;
          }
          final disposed = await registry.update(
            current.copyWith(
              phase: SessionStatePhase.disposed,
              updatedAt: DateTime.now().toUtc(),
            ),
            expectedGeneration: current.generation,
          );
          await registry.deleteDisposed(
            disposed.id,
            expectedGeneration: disposed.generation,
          );
          return SessionStateReconcileEntry(
            lease: current,
            disposition: SessionStateDisposition.forgotten,
            reason:
                'removed the registry record only; no resource data or '
                'reservation marker was touched.',
            resourceMissing: true,
          );
        },
      );
    } on Object catch (error) {
      return SessionStateReconcileEntry(
        lease: snapshotLease,
        disposition: SessionStateDisposition.error,
        reason: 'record-only forget failed: $error',
      );
    }
  }

  Future<SessionStateReconcileEntry> _observeLease(
    final SessionStateLease lease,
  ) async {
    final findings = <SessionStateFinding>[];
    try {
      final host = await registry.hostIdentity(create: false);
      final hostMatches =
          host.canProveSameBoot &&
          lease.hostId == host.hostId &&
          lease.bootId == host.bootId;
      findings.add(
        SessionStateFinding(
          inspectorId: 'oka.host-binding',
          use: hostMatches ? SessionStateUse.unused : SessionStateUse.unknown,
          reason: hostMatches
              ? 'host and boot identity match.'
              : 'host or boot identity could not be verified.',
        ),
      );
    } on Object catch (error) {
      findings.add(
        SessionStateFinding(
          inspectorId: 'oka.host-binding',
          use: SessionStateUse.unknown,
          reason: 'host identity inspection failed: $error',
        ),
      );
    }

    if (lease.resourceKind == SessionStateResourceKind.directory &&
        lease.namespace == SessionStateNamespace.project &&
        lease.ownership == SessionStateOwnership.oka) {
      try {
        final unmaterialized =
            (lease.phase == SessionStatePhase.reserved ||
                lease.phase == SessionStatePhase.partial)
            ? await _checkUnmaterializedReservation(lease)
            : null;
        final rootCheck = unmaterialized ?? await _checkRootAndMarker(lease);
        findings.add(rootCheck.finding);
      } on Object catch (error) {
        findings.add(
          SessionStateFinding(
            inspectorId: 'oka.resource-ownership',
            use: SessionStateUse.unknown,
            reason: 'resource ownership inspection failed: $error',
          ),
        );
      }
    } else {
      findings.add(
        const SessionStateFinding(
          inspectorId: 'oka.resource-ownership',
          use: SessionStateUse.unknown,
          reason: 'resource ownership is not automatically verifiable.',
        ),
      );
    }

    findings.add(
      await _observeProcess(
        inspectorId: 'oka.owner-process',
        pid: lease.ownerPid,
        token: lease.ownerPidToken,
      ),
    );
    if (lease.requiresProcessSnapshot && !lease.hasCompleteProcessSnapshot) {
      findings.add(
        const SessionStateFinding(
          inspectorId: 'oka.associated-process',
          use: SessionStateUse.unknown,
          reason:
              'a process was expected, but no durable associated-process '
              'identity snapshot exists.',
        ),
      );
    }
    if (lease.processPid != null) {
      findings.add(
        await _observeProcess(
          inspectorId: 'oka.associated-process',
          pid: lease.processPid!,
          token: lease.processPidToken,
        ),
      );
    }

    final workflow = _workflowFor(lease);
    if (workflow == null) {
      findings.add(
        SessionStateFinding(
          inspectorId: 'oka.workflow',
          use: SessionStateUse.unknown,
          reason:
              'workflow ${lease.workflowId}@${lease.workflowVersion} is not '
              'composed in this invocation.',
        ),
      );
    } else {
      try {
        final session = await workflow.restoreSession(lease);
        findings.addAll(await session.inspect(lease));
      } on Object catch (error) {
        findings.add(
          SessionStateFinding(
            inspectorId: 'oka.workflow-inspection',
            use: SessionStateUse.unknown,
            reason: 'provider observation failed: $error',
          ),
        );
      }
    }
    return SessionStateReconcileEntry(
      lease: lease,
      disposition: SessionStateDisposition.retained,
      reason: 'read-only inspection; no cleanup was attempted.',
      findings: List.unmodifiable(findings),
    );
  }

  Future<SessionStateFinding> _observeProcess({
    required String inspectorId,
    required int pid,
    required String? token,
  }) async {
    final state = await _processState(pid, token);
    return SessionStateFinding(
      inspectorId: inspectorId,
      use: switch (state) {
        _ProcessState.running => SessionStateUse.busy,
        _ProcessState.stopped => SessionStateUse.unused,
        _ProcessState.unknown => SessionStateUse.unknown,
      },
      reason: switch (state) {
        _ProcessState.running => 'process $pid matches its recorded identity.',
        _ProcessState.stopped =>
          'process $pid is stopped or its PID has been recycled.',
        _ProcessState.unknown =>
          'process $pid could not be positively identified.',
      },
      details: {'pid': pid},
    );
  }

  Future<SessionStateReconcileEntry> _applyLease(
    final SessionStateLease snapshotLease, {
    bool explicitClose = false,
  }) async {
    try {
      return await registry.withResourceLock(
        '${snapshotLease.namespace.label}:${snapshotLease.logicalResourceKey}',
        () async {
          final latestSnapshot = await registry.inspect();
          if (latestSnapshot.issues.isNotEmpty) {
            return _retain(
              snapshotLease,
              'registry contains ${latestSnapshot.issues.length} issue(s); '
              'no resources were changed.',
            );
          }
          final lease = await registry.read(snapshotLease.id);
          if (lease == null) {
            return SessionStateReconcileEntry(
              lease: snapshotLease,
              disposition: SessionStateDisposition.disposed,
              reason: 'record was already removed by another reconciler.',
            );
          }
          if (lease.phase == SessionStatePhase.disposed) {
            await registry.deleteDisposed(
              lease.id,
              expectedGeneration: lease.generation,
            );
            return SessionStateReconcileEntry(
              lease: lease,
              disposition: SessionStateDisposition.disposed,
              reason: 'removed a completed disposal record.',
            );
          }
          if (lease.generation != snapshotLease.generation) {
            return _retain(lease, 'record changed during inspection; retry.');
          }
          final rechecked = await _inspectLease(
            lease,
            explicitClose: explicitClose,
          );
          if (rechecked.disposition != SessionStateDisposition.eligible) {
            return rechecked;
          }
          if (rechecked.resourceMissing) {
            final current = await registry.update(
              lease.copyWith(
                phase: SessionStatePhase.disposing,
                updatedAt: DateTime.now().toUtc(),
              ),
              expectedGeneration: lease.generation,
            );
            await _deleteReservation(current);
            final disposed = await registry.update(
              current.copyWith(
                phase: SessionStatePhase.disposed,
                updatedAt: DateTime.now().toUtc(),
              ),
              expectedGeneration: current.generation,
            );
            await registry.deleteDisposed(
              disposed.id,
              expectedGeneration: disposed.generation,
            );
            return SessionStateReconcileEntry(
              lease: disposed,
              disposition: SessionStateDisposition.disposed,
              reason: 'resource was already missing; removed its stale lease.',
              findings: rechecked.findings,
              resourceMissing: true,
            );
          }
          final workflow = _workflowFor(lease);
          if (workflow == null) {
            return _retain(lease, 'workflow is unavailable.');
          }
          final restored = await workflow.restoreSession(lease);
          final cleanupOwnerToken = await liveness.identityToken(pid);
          if (cleanupOwnerToken == null) {
            return _retain(
              lease,
              'the cleanup process identity could not be recorded; '
              'no cleanup stages were run.',
            );
          }
          var current = await registry.update(
            lease.copyWith(
              phase: SessionStatePhase.disposing,
              ownerPid: pid,
              ownerPidToken: cleanupOwnerToken,
              updatedAt: DateTime.now().toUtc(),
            ),
            expectedGeneration: lease.generation,
          );
          try {
            for (final stepId in restored.cleanupStepIds) {
              if (current.completedCleanupSteps.contains(stepId)) continue;
              await restored.prepareCleanupStep(current, stepId);
              current = await registry.update(
                current.copyWith(
                  completedCleanupSteps: [
                    ...current.completedCleanupSteps,
                    stepId,
                  ],
                  updatedAt: DateTime.now().toUtc(),
                ),
                expectedGeneration: current.generation,
              );
            }
            final finalFindings = await restored.inspect(current);
            final veto = finalFindings.firstWhere(
              (final finding) => finding.use != SessionStateUse.unused,
              orElse: () => const SessionStateFinding(
                inspectorId: 'oka.final-inspection',
                use: SessionStateUse.unused,
                reason: 'all final inspections affirm unused.',
              ),
            );
            if (veto.use != SessionStateUse.unused) {
              throw StateError(
                '${veto.inspectorId}: ${veto.reason}; state retained.',
              );
            }
            current = await _disposeDirectory(current);
            final disposed = await registry.update(
              current.copyWith(
                phase: SessionStatePhase.disposed,
                updatedAt: DateTime.now().toUtc(),
              ),
              expectedGeneration: current.generation,
            );
            await registry.deleteDisposed(
              disposed.id,
              expectedGeneration: disposed.generation,
            );
            return SessionStateReconcileEntry(
              lease: disposed,
              disposition: SessionStateDisposition.disposed,
              reason: 'owned ephemeral state was quarantined and deleted.',
              findings: rechecked.findings,
            );
          } on Object catch (error) {
            final latest = await registry.read(current.id);
            final attemptCount = (latest ?? current).attemptCount + 1;
            final nextPhase = attemptCount >= maxCleanupAttempts
                ? SessionStatePhase.quarantined
                : SessionStatePhase.partial;
            if (latest != null) {
              await registry.update(
                latest.copyWith(
                  phase: nextPhase,
                  updatedAt: DateTime.now().toUtc(),
                  attemptCount: attemptCount,
                  lastError: error.toString(),
                ),
                expectedGeneration: latest.generation,
              );
            }
            return SessionStateReconcileEntry(
              lease: current.copyWith(
                phase: nextPhase,
                attemptCount: attemptCount,
                lastError: error.toString(),
              ),
              disposition: SessionStateDisposition.error,
              reason: nextPhase == SessionStatePhase.quarantined
                  ? 'cleanup attempts exhausted; explicit retry required: $error'
                  : 'partial cleanup; retry is safe: $error',
              findings: rechecked.findings,
            );
          }
        },
      );
    } on Object catch (error) {
      return SessionStateReconcileEntry(
        lease: snapshotLease,
        disposition: SessionStateDisposition.error,
        reason: 'cleanup failed safely: $error',
      );
    }
  }

  Future<SessionStateLease> _disposeDirectory(SessionStateLease lease) async {
    var currentLease = lease;
    final rootPath = p.normalize(p.absolute(lease.rootPath));
    final originalPath = p.normalize(p.join(rootPath, lease.relativePath));
    final verified = await _checkRootAndMarker(lease);
    if (verified.finding.use != SessionStateUse.unused) {
      throw FileSystemException(
        'Final ownership check failed: ${verified.finding.reason}',
        originalPath,
      );
    }
    var quarantineRelative = lease.quarantineRelativePath;
    var quarantinePath = quarantineRelative == null
        ? p.join(
            rootPath,
            p.dirname(lease.relativePath),
            '.oka-quarantine-${lease.id}',
          )
        : p.normalize(p.join(rootPath, quarantineRelative));
    if (!p.isWithin(rootPath, originalPath) ||
        !p.isWithin(rootPath, quarantinePath)) {
      throw const FileSystemException(
        'Refusing to delete a path outside its registered root.',
      );
    }
    var quarantineType = await FileSystemEntity.type(
      quarantinePath,
      followLinks: false,
    );
    if (quarantineType == FileSystemEntityType.notFound) {
      final originalType = await FileSystemEntity.type(
        originalPath,
        followLinks: false,
      );
      if (originalType == FileSystemEntityType.notFound) {
        await _deleteReservation(lease);
        return lease;
      }
      if (originalType != FileSystemEntityType.directory) {
        throw FileSystemException(
          'Owned state path is not a real directory.',
          originalPath,
        );
      }
      if (quarantineRelative == null) {
        quarantineRelative = p.normalize(
          p.join(p.dirname(lease.relativePath), '.oka-quarantine-${lease.id}'),
        );
        quarantinePath = p.join(rootPath, quarantineRelative);
        currentLease = await registry.update(
          currentLease.copyWith(
            phase: SessionStatePhase.disposing,
            quarantineRelativePath: quarantineRelative,
            updatedAt: DateTime.now().toUtc(),
          ),
          expectedGeneration: currentLease.generation,
        );
      }
      await Directory(originalPath).rename(quarantinePath);
      quarantineType = await FileSystemEntity.type(
        quarantinePath,
        followLinks: false,
      );
    }
    if (quarantineType != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Quarantine path is not a real directory.',
        quarantinePath,
      );
    }
    if (!await _markerMatches(
      File(sessionStateOwnershipMarkerPath(quarantinePath)),
      id: currentLease.id,
      nonce: currentLease.markerNonce,
      hostId: currentLease.hostId,
    )) {
      throw FileSystemException(
        'Quarantined state ownership marker is missing or does not match.',
        quarantinePath,
      );
    }
    if (await FileSystemEntity.type(quarantinePath, followLinks: false) ==
        FileSystemEntityType.directory) {
      await Directory(quarantinePath).delete(recursive: true);
    }
    if (await FileSystemEntity.type(quarantinePath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Quarantined state still exists after deletion attempt.',
        quarantinePath,
      );
    }
    await _deleteReservation(currentLease);
    return currentLease;
  }

  Future<void> _deleteReservation(final SessionStateLease lease) async {
    final reservation = File(lease.reservationMarkerPath);
    if (await _hasLinkedPath(lease.rootPath, reservation.path)) {
      throw FileSystemException(
        'Refusing to delete a reservation marker through a symbolic link.',
        reservation.path,
      );
    }
    if (await reservation.exists()) await reservation.delete();
  }

  Future<_RootCheck> _checkRootAndMarker(final SessionStateLease lease) async {
    final rootPath = p.normalize(p.absolute(lease.rootPath));
    final rootType = await FileSystemEntity.type(rootPath, followLinks: false);
    if (rootType != FileSystemEntityType.directory) {
      return const _RootCheck(
        SessionStateFinding(
          inspectorId: 'oka.state-root',
          use: SessionStateUse.unknown,
          reason: 'registered resource root is unavailable; retained.',
        ),
        exists: false,
      );
    }
    if (await _hasLinkedAncestor(rootPath)) {
      return const _RootCheck(
        SessionStateFinding(
          inspectorId: 'oka.state-root',
          use: SessionStateUse.unknown,
          reason: 'registered root or an ancestor is a symbolic link.',
        ),
        exists: false,
      );
    }
    final canonical = await Directory(rootPath).resolveSymbolicLinks();
    if (p.normalize(canonical) != rootPath) {
      return const _RootCheck(
        SessionStateFinding(
          inspectorId: 'oka.state-root',
          use: SessionStateUse.unknown,
          reason: 'registered root no longer resolves to its recorded path.',
        ),
        exists: false,
      );
    }
    final targetPath = p.normalize(p.join(rootPath, lease.relativePath));
    if (!p.isWithin(rootPath, targetPath) ||
        lease.relativePath.contains(r'\') ||
        p.posix.isAbsolute(lease.relativePath) ||
        lease.relativePath.split('/').contains('..')) {
      return const _RootCheck(
        SessionStateFinding(
          inspectorId: 'oka.state-root',
          use: SessionStateUse.unknown,
          reason: 'resource path escapes its registered root.',
        ),
        exists: false,
      );
    }
    var actualRelative = lease.quarantineRelativePath ?? lease.relativePath;
    var actualPath = p.normalize(p.join(rootPath, actualRelative));
    if (lease.quarantineRelativePath != null &&
        await FileSystemEntity.type(actualPath, followLinks: false) ==
            FileSystemEntityType.notFound) {
      actualRelative = lease.relativePath;
      actualPath = p.normalize(p.join(rootPath, actualRelative));
    }
    if (!p.isWithin(rootPath, actualPath) ||
        actualRelative.contains(r'\') ||
        p.posix.isAbsolute(actualRelative) ||
        actualRelative.split('/').contains('..')) {
      return const _RootCheck(
        SessionStateFinding(
          inspectorId: 'oka.state-root',
          use: SessionStateUse.unknown,
          reason: 'quarantine path escapes its registered root.',
        ),
        exists: false,
      );
    }
    if (await _hasLinkedPath(rootPath, actualPath)) {
      return const _RootCheck(
        SessionStateFinding(
          inspectorId: 'oka.state-root',
          use: SessionStateUse.unknown,
          reason: 'resource or an ancestor is a symbolic link.',
        ),
        exists: false,
      );
    }
    final actualType = await FileSystemEntity.type(
      actualPath,
      followLinks: false,
    );
    if (actualType == FileSystemEntityType.notFound) {
      // An existing verified root plus a missing child is a converged branch.
      // No deletion authority is needed because there is no resource left.
      return const _RootCheck(
        SessionStateFinding(
          inspectorId: 'oka.state-root',
          use: SessionStateUse.unused,
          reason: 'resource is already missing under a verified root.',
        ),
        exists: false,
      );
    }
    final reservation = File(lease.reservationMarkerPath);
    if (await _hasLinkedPath(rootPath, reservation.path)) {
      return const _RootCheck(
        SessionStateFinding(
          inspectorId: 'oka.state-root',
          use: SessionStateUse.unknown,
          reason: 'reservation marker path contains a symbolic link.',
        ),
        exists: true,
      );
    }
    if (!await _markerMatches(
      reservation,
      id: lease.id,
      nonce: lease.markerNonce,
      hostId: lease.hostId,
    )) {
      return const _RootCheck(
        SessionStateFinding(
          inspectorId: 'oka.state-marker',
          use: SessionStateUse.unknown,
          reason: 'Oka reservation marker is missing or does not match.',
        ),
        exists: true,
      );
    }
    if (actualType != FileSystemEntityType.directory) {
      return const _RootCheck(
        SessionStateFinding(
          inspectorId: 'oka.state-root',
          use: SessionStateUse.unknown,
          reason: 'resource path is not a real directory.',
        ),
        exists: true,
      );
    }
    final ownerMarker = File(sessionStateOwnershipMarkerPath(actualPath));
    if (!await _markerMatches(
      ownerMarker,
      id: lease.id,
      nonce: lease.markerNonce,
      hostId: lease.hostId,
    )) {
      return const _RootCheck(
        SessionStateFinding(
          inspectorId: 'oka.state-marker',
          use: SessionStateUse.unknown,
          reason: 'resource ownership marker is missing or does not match.',
        ),
        exists: true,
      );
    }
    return const _RootCheck(
      SessionStateFinding(
        inspectorId: 'oka.state-marker',
        use: SessionStateUse.unused,
        reason: 'root containment and Oka ownership markers verified.',
      ),
      exists: true,
    );
  }

  /// Recovers the crash window after the durable lease write but before its
  /// reservation marker is written. This is safe only when the lease remains
  /// in an unmaterialized `reserved` or `partial` phase, the verified root
  /// exists, and the resource path is absent. No filesystem resource is
  /// deleted in this branch.
  Future<_RootCheck?> _checkUnmaterializedReservation(
    final SessionStateLease lease,
  ) async {
    if (lease.quarantineRelativePath != null) return null;
    final rootPath = p.normalize(p.absolute(lease.rootPath));
    if (await FileSystemEntity.type(rootPath, followLinks: false) !=
            FileSystemEntityType.directory ||
        await _hasLinkedAncestor(rootPath)) {
      return null;
    }
    final canonical = await Directory(rootPath).resolveSymbolicLinks();
    if (p.normalize(canonical) != rootPath) return null;

    final relativePath = lease.relativePath;
    final resourcePath = p.normalize(p.join(rootPath, relativePath));
    if (!p.isWithin(rootPath, resourcePath) ||
        relativePath.contains(r'\') ||
        p.posix.isAbsolute(relativePath) ||
        relativePath.split('/').contains('..') ||
        await _hasLinkedPath(rootPath, resourcePath)) {
      return null;
    }
    if (await FileSystemEntity.type(resourcePath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return null;
    }

    final reservationPath = lease.reservationMarkerPath;
    if (!p.isWithin(rootPath, reservationPath) ||
        await _hasLinkedPath(rootPath, reservationPath) ||
        await FileSystemEntity.type(reservationPath, followLinks: false) !=
            FileSystemEntityType.notFound) {
      return null;
    }
    return const _RootCheck(
      SessionStateFinding(
        inspectorId: 'oka.reservation',
        use: SessionStateUse.unused,
        reason:
            'reserved lease has no marker and no resource; provisioning never '
            'materialized state.',
      ),
      exists: false,
    );
  }

  Future<bool> _markerMatches(
    final File file, {
    required final String id,
    required final String nonce,
    required final String hostId,
  }) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    try {
      final value = jsonDecode(await file.readAsString());
      return value is Map &&
          value['id'] == id &&
          value['nonce'] == nonce &&
          value['host_id'] == hostId;
    } on Object {
      return false;
    }
  }

  Future<bool> _hasLinkedAncestor(final String path) async {
    var current = p.normalize(p.absolute(path));
    while (true) {
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        return true;
      }
      final parent = p.dirname(current);
      if (parent == current) return false;
      current = parent;
    }
  }

  Future<bool> _hasLinkedPath(final String root, final String path) async {
    if (!p.isWithin(root, path)) return true;
    var current = root;
    final relative = p.relative(path, from: root);
    for (final part in p.split(relative)) {
      current = p.join(current, part);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        return true;
      }
    }
    return false;
  }

  Future<_ProcessState> _processState(
    final int pid,
    final String? token,
  ) async {
    if (pid <= 0 || token == null || token.isEmpty) {
      return _ProcessState.unknown;
    }
    try {
      if (!await liveness.isAlive(pid)) return _ProcessState.stopped;
      final current = await liveness.identityToken(pid);
      if (current == null) return _ProcessState.unknown;
      return current == token ? _ProcessState.running : _ProcessState.stopped;
    } on Object {
      return _ProcessState.unknown;
    }
  }

  SessionStateWorkflow<dynamic>? _workflowFor(final SessionStateLease lease) {
    for (final workflow in workflows) {
      if (workflow.id == lease.workflowId &&
          workflow.version == lease.workflowVersion) {
        return workflow;
      }
    }
    return null;
  }

  SessionStateReconcileEntry _retain(
    final SessionStateLease lease,
    final String reason,
  ) => SessionStateReconcileEntry(
    lease: lease,
    disposition: SessionStateDisposition.retained,
    reason: reason,
  );
}

final class _RootCheck {
  const _RootCheck(this.finding, {required this.exists});

  final SessionStateFinding finding;
  final bool exists;
}

enum _ProcessState { running, stopped, unknown }
