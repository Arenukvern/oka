/// Reserve and provision managed state without an unjournaled creation gap.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'process_liveness.dart';
import 'session_state.dart';
import 'session_state_reconciler.dart';
import 'session_state_registry.dart';

/// A provisioning failure that leaves its durable lease available for repair.
final class SessionStateProvisionException implements Exception {
  const SessionStateProvisionException({
    required this.leaseId,
    required this.message,
  });

  final String leaseId;
  final String message;

  @override
  String toString() => 'Session-state "$leaseId" is incomplete: $message';
}

/// Executes a workflow's typed provision stages after a durable reservation.
final class SessionStateManager {
  SessionStateManager({
    required this.registry,
    this.liveness = const HostProcessLiveness(),
  });

  final SessionStateRegistry registry;
  final ProcessLiveness liveness;

  /// Records that a process is expected to consume this state resource.
  ///
  /// The marker is committed before spawn so a failure to attach a process
  /// identity cannot be interpreted as proof that no process was created.
  Future<SessionStateLease> expectProcess(final String leaseId) =>
      _updateMetadata(leaseId, {'process_snapshot_required': true});

  /// Clears a pre-spawn expectation only when the launcher confirms that
  /// process creation failed before returning a process handle.
  Future<SessionStateLease> markProcessNotStarted(final String leaseId) =>
      _updateMetadata(leaseId, {'process_snapshot_required': false});

  Future<SessionStateLease> _updateMetadata(
    final String leaseId,
    final Map<String, Object?> changes,
  ) async {
    final lease = await registry.read(leaseId);
    if (lease == null) {
      throw SessionStateRegistryException(
        'Session-state "$leaseId" no longer exists.',
      );
    }
    return registry.withResourceLock(
      '${lease.namespace.label}:${lease.logicalResourceKey}',
      () async {
        final current = await registry.read(leaseId);
        if (current == null) {
          throw SessionStateRegistryException(
            'Session-state "$leaseId" no longer exists.',
          );
        }
        return registry.update(
          current.copyWith(
            metadata: {...current.metadata, ...changes},
            updatedAt: DateTime.now().toUtc(),
          ),
          expectedGeneration: current.generation,
        );
      },
    );
  }

  /// Plans and reserves a resource before running any provision stage.
  ///
  /// A matching ready persistent resource is reused by id. An ephemeral
  /// directory can be reopened in place only when the workflow supplies
  /// explicit reuse inspectors and core verifies every ownership and process
  /// identity proof. Caller-owned resources are borrowed and never provisioned
  /// by Oka.
  Future<SessionStateLease> acquire<H>(
    final SessionStateWorkflow<H> workflow,
    final SessionStateRequest request,
  ) async {
    final workflowIssues = workflow.validate();
    if (workflowIssues.isNotEmpty) {
      throw ArgumentError(
        'Invalid session-state workflow:\n'
        '${workflowIssues.map((final issue) => '  - $issue').join('\n')}',
      );
    }
    final plan = workflow.plan.plan(request);
    final planIssues = plan.validate();
    if (planIssues.isNotEmpty) {
      throw ArgumentError(
        'Invalid session-state plan:\n'
        '${planIssues.map((final issue) => '  - $issue').join('\n')}',
      );
    }

    final host = await registry.hostIdentity();
    if (!host.canProveSameBoot) {
      throw const SessionStateRegistryException(
        'This host cannot provide a boot identity; managed state creation is '
        'disabled rather than recording an unreconcilable lease.',
      );
    }
    final ownerToken = await liveness.identityToken(pid);
    if (ownerToken == null) {
      throw const SessionStateRegistryException(
        'The current Oka process identity is unavailable; state provisioning '
        'was not started.',
      );
    }

    final rootPath = plan.rootPath.isEmpty
        ? ''
        : p.normalize(p.absolute(plan.rootPath));
    var canonicalRoot = rootPath;
    if (rootPath.isNotEmpty) {
      final root = Directory(rootPath);
      if (await FileSystemEntity.type(root.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        if (plan.ownership == SessionStateOwnership.oka &&
            plan.resourceKind == SessionStateResourceKind.directory) {
          throw SessionStateRegistryException(
            'Session-state root "${root.path}" must exist as a real directory '
            'before acquisition.',
          );
        }
      } else {
        canonicalRoot = p.normalize(await root.resolveSymbolicLinks());
      }
    }
    final projectPath = await Directory(
      request.projectPath,
    ).resolveSymbolicLinks();
    final resourcePath = canonicalRoot.isEmpty
        ? ''
        : p.normalize(p.join(canonicalRoot, plan.relativePath));
    if (plan.resourceKind == SessionStateResourceKind.directory &&
        (canonicalRoot.isEmpty || !p.isWithin(canonicalRoot, resourcePath))) {
      throw const SessionStateRegistryException(
        'Session-state path escapes its declared root.',
      );
    }
    if (plan.ownership == SessionStateOwnership.oka &&
        plan.resourceKind == SessionStateResourceKind.directory &&
        await _hasLinkedPath(canonicalRoot, resourcePath)) {
      throw SessionStateRegistryException(
        'Session-state path "$resourcePath" contains a symbolic-link ancestor.',
      );
    }
    if (plan.ownership == SessionStateOwnership.caller &&
        plan.resourceKind == SessionStateResourceKind.directory &&
        await FileSystemEntity.type(resourcePath, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw SessionStateRegistryException(
        'Borrowed session-state directory "$resourcePath" does not exist as '
        'a real directory.',
      );
    }
    final id = registry.newId();
    final markerNonce = registry.newId();
    final now = DateTime.now().toUtc();
    String? cleanupDisposition;

    // Keep legacy cleanup-before-fresh-acquisition behavior only for workflows
    // that do not opt into in-place reuse. Explicit reuse workflows must make
    // their ready-lease decision under the resource lock below; this prevents
    // cleanup from deleting the very lease they intend to reopen.
    if (plan.retention == SessionStateRetention.ephemeral &&
        workflow.reuseInspectors == null) {
      final snapshot = await registry.inspect();
      final existing = snapshot.leases.where(
        (final lease) =>
            lease.namespace == plan.namespace &&
            lease.logicalResourceKey == plan.logicalResourceKey,
      );
      if (snapshot.issues.isEmpty &&
          existing.length == 1 &&
          existing.single.workflowId == workflow.id &&
          existing.single.workflowVersion == workflow.version &&
          existing.single.retention == SessionStateRetention.ephemeral) {
        final report = await SessionStateReconciler(
          registry: registry,
          workflows: [workflow],
          liveness: liveness,
        ).reconcileLease(leaseId: existing.single.id, apply: true);
        if (report.entries.isNotEmpty &&
            report.entries.single.disposition !=
                SessionStateDisposition.disposed) {
          final entry = report.entries.single;
          cleanupDisposition =
              'Cleanup of lease "${entry.lease.id}" reported '
              '${entry.disposition.name}: ${entry.reason}';
        }
      }
    }

    return registry.withResourceLock(
      '${plan.namespace.label}:${plan.logicalResourceKey}',
      () async {
        final snapshot = await registry.inspect();
        if (snapshot.issues.isNotEmpty) {
          throw SessionStateRegistryException(
            'Session-state registry has ${snapshot.issues.length} issue(s); '
            'provisioning is blocked until they are inspected.',
          );
        }
        final existing = snapshot.leases.where(
          (final lease) =>
              lease.namespace == plan.namespace &&
              lease.logicalResourceKey == plan.logicalResourceKey,
        );
        if (existing.isNotEmpty) {
          if (existing.length != 1) {
            throw SessionStateRegistryException(
              'Resource "${plan.logicalResourceKey}" has multiple state '
              'leases; inspect the registry before reusing it.',
            );
          }
          final current = existing.first;
          final hasMatchingIdentity =
              current.phase == SessionStatePhase.ready &&
              current.workflowId == workflow.id &&
              current.workflowVersion == workflow.version &&
              current.retention == plan.retention &&
              current.processScope == plan.processScope &&
              current.ownership == plan.ownership &&
              (current.ownership == SessionStateOwnership.oka
                  ? current.acquisitionMode !=
                            SessionStateAcquisitionMode.borrowed &&
                        plan.acquisitionMode !=
                            SessionStateAcquisitionMode.borrowed
                  : current.acquisitionMode ==
                            SessionStateAcquisitionMode.borrowed &&
                        plan.acquisitionMode ==
                            SessionStateAcquisitionMode.borrowed) &&
              current.rootPath == canonicalRoot &&
              current.relativePath == plan.relativePath &&
              current.hostId == host.hostId;
          final isEphemeralReuse =
              plan.retention == SessionStateRetention.ephemeral &&
              workflow.reuseInspectors != null &&
              hasMatchingIdentity &&
              current.ownership == SessionStateOwnership.oka &&
              plan.ownership == SessionStateOwnership.oka &&
              current.resourceKind == SessionStateResourceKind.directory &&
              plan.resourceKind == SessionStateResourceKind.directory &&
              current.bootId == host.bootId &&
              current.ownerProject == projectPath &&
              current.quarantineRelativePath == null;
          final isReusable =
              (plan.retention != SessionStateRetention.ephemeral &&
                  hasMatchingIdentity) ||
              isEphemeralReuse;
          if (isReusable) {
            if (isEphemeralReuse) {
              await _verifyExistingManagedResource(current);
              await _verifyReservationEvidence(current);
              await _requireOwnerStoppedOrCurrent(current, pid, ownerToken);
              await _requireAssociatedProcessStopped(current);
              await _requireResourceUnused(workflow, current);
            } else if (current.ownership == SessionStateOwnership.oka &&
                current.resourceKind == SessionStateResourceKind.directory) {
              await _verifyExistingManagedResource(current);
              await _requireOwnerStoppedOrCurrent(current, pid, ownerToken);
              await _requireAssociatedProcessStopped(current);
              await _requireResourceUnused(workflow, current);
            }
            final managesDirectory =
                current.ownership == SessionStateOwnership.oka &&
                current.resourceKind == SessionStateResourceKind.directory;
            final reusable = managesDirectory && !isEphemeralReuse
                ? current.copyWith(reservationMarkerAdjacent: true)
                : current;
            if (managesDirectory && !isEphemeralReuse) {
              await _ensureReservationMarker(reusable);
            }
            return registry.update(
              reusable.copyWith(
                acquisitionMode: current.ownership == SessionStateOwnership.oka
                    ? SessionStateAcquisitionMode.reused
                    : SessionStateAcquisitionMode.borrowed,
                hostId: host.hostId,
                bootId: host.bootId,
                ownerProject: projectPath,
                ownerPid: pid,
                ownerPidToken: ownerToken,
                clearProcessIdentity: isEphemeralReuse,
                updatedAt: DateTime.now().toUtc(),
                metadata: {
                  ...current.metadata,
                  ...plan.metadata,
                  if (isEphemeralReuse) 'process_snapshot_required': false,
                },
              ),
              expectedGeneration: current.generation,
            );
          }
          throw SessionStateRegistryException(
            'Resource "${plan.logicalResourceKey}" is already reserved by '
            'state lease "${current.id}" (${current.phase.label}); inspect or '
            'repair that lease before acquiring it again. Run '
            '"oka session-state inspect ${current.id} --verbose", then '
            '"oka session-state reconcile --apply" if its findings are safe.'
            '${cleanupDisposition == null ? '' : ' $cleanupDisposition'}',
          );
        }

        if (plan.ownership == SessionStateOwnership.oka &&
            plan.acquisitionMode == SessionStateAcquisitionMode.reused) {
          throw SessionStateRegistryException(
            'Resource "${plan.logicalResourceKey}" is marked reused but has '
            'no matching Oka lease proving its ownership; acquire it as '
            'borrowed or create a new Oka-managed resource.',
          );
        }
        if (plan.ownership == SessionStateOwnership.oka &&
            plan.resourceKind == SessionStateResourceKind.directory &&
            await FileSystemEntity.type(resourcePath, followLinks: false) !=
                FileSystemEntityType.notFound) {
          throw SessionStateRegistryException(
            'Resource path "$resourcePath" already exists without a matching '
            'Oka state lease; it will not be silently adopted. Remedies: '
            'configure it as caller-owned/borrowed if that is intentional, or '
            'verify and move the existing data before retrying.',
          );
        }

        final lease = SessionStateLease(
          id: id,
          workflowId: workflow.id,
          workflowVersion: workflow.version,
          logicalResourceKey: plan.logicalResourceKey,
          namespace: plan.namespace,
          retention: plan.retention,
          processScope: plan.processScope,
          ownership: plan.ownership,
          acquisitionMode: plan.acquisitionMode,
          phase: SessionStatePhase.reserved,
          resourceKind: plan.resourceKind,
          rootPath: canonicalRoot,
          relativePath: plan.relativePath,
          markerNonce: markerNonce,
          reservationMarkerAdjacent: true,
          hostId: host.hostId,
          bootId: host.bootId,
          ownerProject: projectPath,
          ownerPid: pid,
          ownerPidToken: ownerToken,
          createdAt: now,
          updatedAt: now,
          metadata: plan.metadata,
        );
        await registry.create(lease);

        try {
          if (plan.ownership == SessionStateOwnership.oka &&
              plan.resourceKind == SessionStateResourceKind.directory) {
            await _writeReservationMarker(lease);
          }
          final current = await registry.update(
            lease.copyWith(
              phase: SessionStatePhase.provisioning,
              updatedAt: DateTime.now().toUtc(),
            ),
            expectedGeneration: lease.generation,
          );
          if (plan.ownership == SessionStateOwnership.oka) {
            if (plan.resourceKind == SessionStateResourceKind.directory) {
              await _createManagedDirectory(resourcePath, lease);
              await _writeOwnershipMarker(resourcePath, current);
            }
            final context = SessionStateContext(
              handle: plan.handle,
              lease: current,
            );
            for (final step in workflow.provision) {
              _validateArtifacts(step, context);
              await step.run(context);
              _validateProvidedArtifacts(step, context);
            }
          }
          return await registry.update(
            current.copyWith(
              phase: SessionStatePhase.ready,
              updatedAt: DateTime.now().toUtc(),
            ),
            expectedGeneration: current.generation,
          );
        } on Object catch (error) {
          final latest = await registry.read(lease.id);
          if (latest != null && latest.phase != SessionStatePhase.quarantined) {
            await registry.update(
              latest.copyWith(
                phase: SessionStatePhase.partial,
                updatedAt: DateTime.now().toUtc(),
                attemptCount: latest.attemptCount + 1,
                lastError: error.toString(),
              ),
              expectedGeneration: latest.generation,
            );
          }
          throw SessionStateProvisionException(
            leaseId: lease.id,
            message: error.toString(),
          );
        }
      },
    );
  }

  /// Explicitly resumes an interrupted, Oka-owned directory provisioning run.
  ///
  /// Provision stages are run from the beginning and must therefore remain
  /// idempotent. Resume never adopts borrowed/opaque resources or repairs
  /// missing reservation evidence.
  Future<SessionStateLease> resume<H>(
    final SessionStateWorkflow<H> workflow,
    final String leaseId,
  ) async {
    final workflowIssues = workflow.validate();
    if (workflowIssues.isNotEmpty) {
      throw ArgumentError(
        'Invalid session-state workflow:\n'
        '${workflowIssues.map((final issue) => '  - $issue').join('\n')}',
      );
    }
    final initial = await registry.read(leaseId);
    if (initial == null) {
      throw SessionStateRegistryException(
        'No session-state lease found with id "$leaseId".',
      );
    }
    return registry.withResourceLock(
      '${initial.namespace.label}:${initial.logicalResourceKey}',
      () async {
        final lease = await registry.read(leaseId);
        if (lease == null || lease.generation != initial.generation) {
          throw SessionStateRegistryException(
            'Session-state "$leaseId" changed before resume; inspect it '
            'before trying again.',
          );
        }
        if (lease.workflowId != workflow.id ||
            lease.workflowVersion != workflow.version) {
          throw SessionStateRegistryException(
            'Session-state "$leaseId" belongs to '
            '${lease.workflowId}@${lease.workflowVersion}, not '
            '${workflow.id}@${workflow.version}.',
          );
        }
        if (!{
          SessionStatePhase.reserved,
          SessionStatePhase.provisioning,
          SessionStatePhase.partial,
        }.contains(lease.phase)) {
          throw SessionStateRegistryException(
            'Session-state "$leaseId" cannot be resumed from phase '
            '"${lease.phase.label}".',
          );
        }
        if (lease.ownership != SessionStateOwnership.oka ||
            lease.resourceKind != SessionStateResourceKind.directory) {
          throw SessionStateRegistryException(
            'Only Oka-owned directory leases can be resumed; '
            '"$leaseId" is ${lease.ownership.label}-owned '
            '${lease.resourceKind.label} state.',
          );
        }

        final host = await registry.hostIdentity();
        if (!host.canProveSameBoot || lease.hostId != host.hostId) {
          throw SessionStateRegistryException(
            'Managed state "$leaseId" belongs to a different or unverifiable '
            'host; resume is disabled.',
          );
        }
        final ownerToken = await liveness.identityToken(pid);
        if (ownerToken == null) {
          throw const SessionStateRegistryException(
            'The current Oka process identity is unavailable; resume was '
            'not started.',
          );
        }
        await _requireOwnerStoppedOrCurrent(lease, pid, ownerToken);
        await _requireAssociatedProcessStopped(lease);
        final resourcePath = p.join(lease.rootPath, lease.relativePath);
        await _verifyResumeEvidence(lease, resourcePath);
        await _requireResourceUnused(workflow, lease);

        final projectPath = await Directory.current.resolveSymbolicLinks();
        final latest = await registry.read(leaseId);
        if (latest == null || latest.generation != lease.generation) {
          throw SessionStateRegistryException(
            'Session-state "$leaseId" changed during resume checks; '
            'inspect it before trying again.',
          );
        }
        final preparing = await registry.update(
          latest.copyWith(
            phase: SessionStatePhase.provisioning,
            hostId: host.hostId,
            bootId: host.bootId,
            ownerProject: projectPath,
            ownerPid: pid,
            ownerPidToken: ownerToken,
            updatedAt: DateTime.now().toUtc(),
          ),
          expectedGeneration: latest.generation,
        );

        try {
          await _prepareResumeResource(resourcePath, preparing);
          final session = await workflow.restoreSession(preparing);
          await session.provision(preparing);
          return await registry.update(
            preparing.copyWith(
              phase: SessionStatePhase.ready,
              updatedAt: DateTime.now().toUtc(),
              clearLastError: true,
            ),
            expectedGeneration: preparing.generation,
          );
        } on Object catch (error) {
          final current = await registry.read(leaseId);
          if (current != null &&
              current.phase != SessionStatePhase.quarantined) {
            await registry.update(
              current.copyWith(
                phase: SessionStatePhase.partial,
                updatedAt: DateTime.now().toUtc(),
                attemptCount: current.attemptCount + 1,
                lastError: error.toString(),
              ),
              expectedGeneration: current.generation,
            );
          }
          throw SessionStateProvisionException(
            leaseId: leaseId,
            message: error.toString(),
          );
        }
      },
    );
  }

  /// Attaches process identity after spawn. If this durable write fails, the
  /// caller must stop its live process handle before returning.
  Future<SessionStateLease> attachProcess({
    required String leaseId,
    required String processLeaseId,
    required int processPid,
    required String? processPidToken,
  }) async {
    final lease = await registry.read(leaseId);
    if (lease == null) {
      throw SessionStateRegistryException(
        'Session-state lease "$leaseId" disappeared before process attach.',
      );
    }
    return registry.withResourceLock(
      '${lease.namespace.label}:${lease.logicalResourceKey}',
      () async {
        final current = await registry.read(leaseId);
        if (current == null || current.phase != SessionStatePhase.ready) {
          throw SessionStateRegistryException(
            'Session-state "$leaseId" is no longer ready for process attach.',
          );
        }
        return registry.update(
          current.copyWith(
            processLeaseId: processLeaseId,
            processPid: processPid,
            processPidToken: processPidToken,
            updatedAt: DateTime.now().toUtc(),
            clearProcessIdentity: true,
          ),
          expectedGeneration: current.generation,
        );
      },
    );
  }

  Future<void> _writeReservationMarker(final SessionStateLease lease) async {
    await _ensureReservationMarker(lease);
  }

  Future<void> _ensureReservationMarker(final SessionStateLease lease) async {
    final marker = File(lease.reservationMarkerPath);
    if (await _hasLinkedPath(lease.rootPath, marker.path)) {
      throw SessionStateRegistryException(
        'Session-state reservation path "${marker.path}" contains a '
        'symbolic-link ancestor.',
      );
    }
    if (await FileSystemEntity.type(marker.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      if (await _markerMatches(
        marker,
        id: lease.id,
        nonce: lease.markerNonce,
        hostId: lease.hostId,
      )) {
        return;
      }
      throw SessionStateRegistryException(
        'Session-state reservation marker "${marker.path}" exists but does '
        'not match lease "${lease.id}".',
      );
    }
    await marker.parent.create(recursive: true);
    await marker.create(exclusive: true);
    await marker.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'id': lease.id, 'nonce': lease.markerNonce, 'host_id': lease.hostId})}\n',
      flush: true,
    );
  }

  Future<void> _verifyExistingManagedResource(
    final SessionStateLease lease,
  ) async {
    final resourcePath = p.join(lease.rootPath, lease.relativePath);
    if (await _hasLinkedPath(lease.rootPath, resourcePath) ||
        await FileSystemEntity.type(resourcePath, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw SessionStateRegistryException(
        'Managed state resource for "${lease.id}" is not a safe directory.',
      );
    }
    final marker = File(sessionStateOwnershipMarkerPath(resourcePath));
    if (!await _markerMatches(
      marker,
      id: lease.id,
      nonce: lease.markerNonce,
      hostId: lease.hostId,
      rootPath: lease.rootPath,
      relativePath: lease.relativePath,
    )) {
      throw SessionStateRegistryException(
        'Managed state ownership marker for "${lease.id}" is missing or '
        'does not match; the existing resource will not be adopted.',
      );
    }
  }

  Future<void> _verifyReservationEvidence(final SessionStateLease lease) async {
    final marker = File(lease.reservationMarkerPath);
    if (await _hasLinkedPath(lease.rootPath, marker.path) ||
        !await _markerMatches(
          marker,
          id: lease.id,
          nonce: lease.markerNonce,
          hostId: lease.hostId,
        )) {
      throw SessionStateRegistryException(
        'Session-state reservation marker for "${lease.id}" is missing or '
        'does not match; the existing resource will not be reused.',
      );
    }
  }

  Future<void> _verifyResumeEvidence(
    final SessionStateLease lease,
    final String resourcePath,
  ) async {
    final root = Directory(lease.rootPath);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        p.normalize(await root.resolveSymbolicLinks()) !=
            p.normalize(p.absolute(root.path))) {
      throw SessionStateRegistryException(
        'Managed state root for "${lease.id}" is not a safe real directory.',
      );
    }
    final reservationMarker = File(lease.reservationMarkerPath);
    if (await _hasLinkedPath(lease.rootPath, reservationMarker.path) ||
        !await _markerMatches(
          reservationMarker,
          id: lease.id,
          nonce: lease.markerNonce,
          hostId: lease.hostId,
        )) {
      throw SessionStateRegistryException(
        'Session-state reservation marker for "${lease.id}" is missing or '
        'does not match; resume cannot prove that reservation preceded '
        'resource creation.',
      );
    }
    if (!p.isWithin(lease.rootPath, resourcePath) ||
        await _hasLinkedPath(lease.rootPath, resourcePath)) {
      throw SessionStateRegistryException(
        'Managed state path for "${lease.id}" escapes its root or contains a '
        'symbolic-link ancestor.',
      );
    }
    final type = await FileSystemEntity.type(resourcePath, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw SessionStateRegistryException(
        'Managed state resource for "${lease.id}" is not a real directory.',
      );
    }
    if (type == FileSystemEntityType.directory) {
      final marker = File(sessionStateOwnershipMarkerPath(resourcePath));
      if (await _hasLinkedPath(lease.rootPath, marker.path)) {
        throw SessionStateRegistryException(
          'Managed state ownership marker for "${lease.id}" is beneath a '
          'symbolic-link ancestor.',
        );
      }
      if (await FileSystemEntity.type(marker.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        await for (final _ in Directory(
          resourcePath,
        ).list(followLinks: false)) {
          throw SessionStateRegistryException(
            'Managed state ownership marker for "${lease.id}" is missing and '
            'the existing directory is not empty; resume will not adopt it.',
          );
        }
      } else if (!await _markerMatches(
        marker,
        id: lease.id,
        nonce: lease.markerNonce,
        hostId: lease.hostId,
        rootPath: lease.rootPath,
        relativePath: lease.relativePath,
      )) {
        throw SessionStateRegistryException(
          'Managed state ownership marker for "${lease.id}" is missing or '
          'does not match; resume will not adopt the existing directory.',
        );
      }
    }
  }

  Future<void> _prepareResumeResource(
    final String resourcePath,
    final SessionStateLease lease,
  ) async {
    await _verifyResumeEvidence(lease, resourcePath);
    if (await FileSystemEntity.type(resourcePath, followLinks: false) ==
        FileSystemEntityType.notFound) {
      await _createManagedDirectory(resourcePath, lease);
    } else {
      await _restrictManagedDirectoryPermissions(resourcePath, lease.rootPath);
    }
    final marker = File(sessionStateOwnershipMarkerPath(resourcePath));
    if (await FileSystemEntity.type(marker.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      await _verifyResumeEvidence(lease, resourcePath);
      await _writeOwnershipMarker(resourcePath, lease);
    } else {
      await _verifyExistingManagedResource(lease);
    }
  }

  Future<void> _requireOwnerStoppedOrCurrent(
    final SessionStateLease lease,
    final int currentPid,
    final String currentToken,
  ) async {
    if (lease.ownerPid == currentPid && lease.ownerPidToken == currentToken) {
      return;
    }
    final state = await _processMatches(lease.ownerPid, lease.ownerPidToken);
    if (state != false) {
      throw SessionStateRegistryException(
        state == true
            ? 'Managed state "${lease.id}" is still reserved by live Oka '
                  'process ${lease.ownerPid}.'
            : 'The previous Oka owner of "${lease.id}" cannot be verified; '
                  'the managed state remains reserved.',
      );
    }
  }

  Future<void> _requireAssociatedProcessStopped(
    final SessionStateLease lease,
  ) async {
    if (lease.requiresProcessSnapshot && !lease.hasCompleteProcessSnapshot) {
      throw SessionStateRegistryException(
        'Managed state "${lease.id}" refers to an associated process but '
        'has no complete process identity snapshot; inspect the lease before '
        'reuse.',
      );
    }
    if (!lease.hasCompleteProcessSnapshot) return;
    final processPid = lease.processPid!;
    final state = await _processMatches(processPid, lease.processPidToken);
    if (state != false) {
      throw SessionStateRegistryException(
        state == true
            ? 'Managed state "${lease.id}" is still used by recorded process '
                  '$processPid.'
            : 'The recorded process for "${lease.id}" cannot be verified; '
                  'the managed state remains reserved.',
      );
    }
  }

  Future<void> _requireResourceUnused<H>(
    final SessionStateWorkflow<H> workflow,
    final SessionStateLease lease,
  ) async {
    if ((workflow.reuseInspectors ?? workflow.inspectors).isEmpty) {
      throw SessionStateRegistryException(
        'Managed state "${lease.id}" has no use inspector; it cannot be '
        'safely reused.',
      );
    }
    final session = await workflow.restoreSession(lease, forReuse: true);
    final findings = await session.inspect(lease);
    final blockers = findings.where(
      (final finding) => finding.use != SessionStateUse.unused,
    );
    if (blockers.isNotEmpty) {
      final blocker = blockers.first;
      throw SessionStateRegistryException(
        'Managed state "${lease.id}" is not safe to reuse: '
        '${blocker.inspectorId}: ${blocker.reason}',
      );
    }
  }

  Future<bool?> _processMatches(final int pid, final String? token) async {
    if (pid <= 0 || token == null || token.isEmpty) return null;
    try {
      if (!await liveness.isAlive(pid)) return false;
      final current = await liveness.identityToken(pid);
      if (current == null) return null;
      return current == token;
    } on Object {
      return null;
    }
  }

  Future<bool> _markerMatches(
    final File file, {
    required String id,
    required String nonce,
    required String hostId,
    String? rootPath,
    String? relativePath,
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
          value['host_id'] == hostId &&
          (rootPath == null || value['root_path'] == rootPath) &&
          (relativePath == null || value['relative_path'] == relativePath);
    } on Object {
      return false;
    }
  }

  Future<void> _writeOwnershipMarker(
    final String resourcePath,
    final SessionStateLease lease,
  ) async {
    final type = await FileSystemEntity.type(resourcePath, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw SessionStateRegistryException(
        'Provisioning did not create a real directory at "$resourcePath".',
      );
    }
    final marker = File(sessionStateOwnershipMarkerPath(resourcePath));
    await marker.create(exclusive: true);
    await marker.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'id': lease.id, 'nonce': lease.markerNonce, 'host_id': lease.hostId, 'root_path': lease.rootPath, 'relative_path': lease.relativePath})}\n',
      flush: true,
    );
  }

  /// Oka creates the state directory before provider stages write browser
  /// data. POSIX hosts enforce mode 0700; Windows inherits ACLs that dart:io
  /// cannot verify. The ownership marker is written before provisioning.
  Future<void> _createManagedDirectory(
    final String resourcePath,
    final SessionStateLease lease,
  ) async {
    if (!Platform.isLinux && !Platform.isMacOS && !Platform.isWindows) {
      throw UnsupportedError(
        'Oka-managed directory permissions are not verified on this host OS.',
      );
    }
    final rootPath = lease.rootPath;
    if (await _hasLinkedPath(rootPath, resourcePath)) {
      throw SessionStateRegistryException(
        'Managed state path "$resourcePath" contains a symbolic-link ancestor.',
      );
    }
    await Directory(p.dirname(resourcePath)).create(recursive: true);
    await Directory(resourcePath).create();
    await _restrictManagedDirectoryPermissions(resourcePath, rootPath);
    if (await FileSystemEntity.type(resourcePath, followLinks: false) !=
            FileSystemEntityType.directory ||
        await _hasLinkedPath(rootPath, resourcePath)) {
      throw const SessionStateRegistryException(
        'Managed state path changed during creation; provisioning stopped.',
      );
    }
  }

  Future<void> _restrictManagedDirectoryPermissions(
    final String resourcePath,
    final String rootPath,
  ) async {
    if (Platform.isWindows) return;
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw UnsupportedError(
        'Managed state directory permissions are not verified on this host OS.',
      );
    }
    if (await FileSystemEntity.type(resourcePath, followLinks: false) !=
            FileSystemEntityType.directory ||
        await _hasLinkedPath(rootPath, resourcePath)) {
      throw SessionStateRegistryException(
        'Managed state path "$resourcePath" is not a safe real directory.',
      );
    }
    final chmod = await Process.run('chmod', ['700', resourcePath]);
    if (chmod.exitCode != 0) {
      throw SessionStateRegistryException(
        'Could not restrict managed state directory permissions: '
        '${chmod.stderr.toString().trim()}',
      );
    }
    final mode = (await Directory(resourcePath).stat()).mode & 0x1ff;
    if (mode != 0x1c0) {
      throw SessionStateRegistryException(
        'Managed state directory "$resourcePath" is not owner-only after '
        'permission hardening.',
      );
    }
  }

  void _validateArtifacts<H>(
    final SessionStateProvisionStep<H> step,
    final SessionStateContext<H> context,
  ) {
    for (final artifact in step.requires) {
      if (!context.artifacts.containsKey(artifact.id) ||
          !artifact.accepts(context.artifacts[artifact.id])) {
        throw StateError(
          'Provision step "${step.id}" requires artifact '
          '"${artifact.id}" before it is available.',
        );
      }
    }
  }

  void _validateProvidedArtifacts<H>(
    final SessionStateProvisionStep<H> step,
    final SessionStateContext<H> context,
  ) {
    for (final artifact in step.provides) {
      final value = context.artifacts[artifact.id];
      if (!context.artifacts.containsKey(artifact.id) ||
          !artifact.accepts(value)) {
        throw StateError(
          'Provision step "${step.id}" did not provide artifact '
          '"${artifact.id}" with the declared type.',
        );
      }
    }
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
