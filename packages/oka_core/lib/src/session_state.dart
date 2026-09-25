/// Composable contracts for durable browser/emulator session state (ADR-0025).
///
/// These values describe resources, not processes. A state lease survives
/// process-lease cleanup and is reconciled only when the owning workflow is
/// composed and all required evidence is affirmative.
library;

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'pipeline/pipeline.dart';
import 'process_lease.dart';

/// Whether a resource is project-local or shared by the host.
enum SessionStateNamespace {
  /// Scoped to one canonical Oka project.
  project,

  /// Host-wide (for example, an Android AVD).
  host;

  String get label => name;

  static SessionStateNamespace fromLabel(final String label) =>
      SessionStateNamespace.values.firstWhere(
        (final value) => value.label == label,
        orElse: () =>
            throw FormatException('Unknown session-state namespace "$label".'),
      );
}

/// How long state is retained independently of its owning process.
enum SessionStateRetention {
  /// May be removed after a verified normal end or proven-stale recovery.
  ephemeral,

  /// Lives until the owning named session is explicitly closed.
  session,

  /// Never removed automatically.
  persistent;

  String get label => name;

  static SessionStateRetention fromLabel(final String label) =>
      SessionStateRetention.values.firstWhere(
        (final value) => value.label == label,
        orElse: () =>
            throw FormatException('Unknown session-state retention "$label".'),
      );
}

/// Who owns the state resource itself, not the process using it.
enum SessionStateOwnership {
  /// Oka created the resource beneath an Oka-controlled root.
  oka,

  /// The resource belongs to the caller or another tool.
  caller;

  String get label => name;

  static SessionStateOwnership fromLabel(final String label) =>
      SessionStateOwnership.values.firstWhere(
        (final value) => value.label == label,
        orElse: () =>
            throw FormatException('Unknown session-state ownership "$label".'),
      );
}

/// How this acquisition relates to the resource.
enum SessionStateAcquisitionMode {
  created,
  reused,
  borrowed;

  String get label => name;

  static SessionStateAcquisitionMode fromLabel(final String label) =>
      SessionStateAcquisitionMode.values.firstWhere(
        (final value) => value.label == label,
        orElse: () => throw FormatException(
          'Unknown session-state acquisition mode "$label".',
        ),
      );
}

/// Durable lifecycle phase.
enum SessionStatePhase {
  reserved,
  provisioning,
  ready,
  disposing,
  partial,
  quarantined,
  disposed;

  String get label => name;

  static SessionStatePhase fromLabel(final String label) =>
      SessionStatePhase.values.firstWhere(
        (final value) => value.label == label,
        orElse: () =>
            throw FormatException('Unknown session-state phase "$label".'),
      );
}

/// A filesystem tree Oka can manage, or a resource that needs its own API.
enum SessionStateResourceKind {
  /// A directory created beneath the root recorded on the lease.
  directory,

  /// Opaque resource such as an AVD or a remote browser task.
  opaque;

  String get label => name;

  static SessionStateResourceKind fromLabel(final String label) =>
      SessionStateResourceKind.values.firstWhere(
        (final value) => value.label == label,
        orElse: () => throw FormatException(
          'Unknown session-state resource kind "$label".',
        ),
      );
}

/// A versioned durable pointer to one state resource.
///
/// Paths are split into [rootPath] and [relativePath]. Both are untrusted
/// registry data; callers must re-check containment and ownership markers
/// before any filesystem operation. This record never stores profile content
/// or credentials.
@immutable
final class SessionStateLease {
  /// Creates a lease. [id] must be an opaque, path-safe acquisition id.
  const SessionStateLease({
    required this.id,
    required this.workflowId,
    required this.workflowVersion,
    required this.logicalResourceKey,
    required this.namespace,
    required this.retention,
    required this.processScope,
    required this.ownership,
    required this.acquisitionMode,
    required this.phase,
    required this.resourceKind,
    required this.rootPath,
    required this.relativePath,
    required this.markerNonce,
    required this.hostId,
    required this.bootId,
    required this.ownerProject,
    required this.ownerPid,
    required this.ownerPidToken,
    required this.createdAt,
    required this.updatedAt,
    this.processLeaseId,
    this.processPid,
    this.processPidToken,
    this.quarantineRelativePath,
    this.attemptCount = 0,
    this.lastError,
    this.completedCleanupSteps = const [],
    this.metadata = const {},
    this.generation = 0,
    this.reservationMarkerAdjacent = false,
  });

  factory SessionStateLease.fromJson(final Object? value) {
    if (value is! Map) {
      throw const FormatException(
        'Session-state record must be a JSON object.',
      );
    }
    final map = value.cast<String, Object?>();
    const knownFields = {
      'schema_version',
      'id',
      'workflow_id',
      'workflow_version',
      'logical_resource_key',
      'namespace',
      'retention',
      'process_scope',
      'ownership',
      'acquisition_mode',
      'phase',
      'resource_kind',
      'root_path',
      'relative_path',
      'marker_nonce',
      'host_id',
      'boot_id',
      'owner_project',
      'owner_pid',
      'owner_pid_token',
      'process_lease_id',
      'process_pid',
      'process_pid_token',
      'quarantine_relative_path',
      'created_at',
      'updated_at',
      'attempt_count',
      'last_error',
      'completed_cleanup_steps',
      'metadata',
      'generation',
      'reservation_marker_adjacent',
    };
    final unknownFields = map.keys.where(
      (final key) => !knownFields.contains(key),
    );
    if (unknownFields.isNotEmpty) {
      throw FormatException(
        'Session-state record contains unknown field(s) '
        '"${unknownFields.join(', ')}"; retaining it without rewrite.',
      );
    }
    final schema = map['schema_version'];
    if (schema != schemaVersion) {
      throw FormatException(
        'Unsupported session-state schema version "$schema"; '
        'this Oka understands $schemaVersion and will retain the record.',
      );
    }
    final metadataValue = map['metadata'];
    if (metadataValue is! Map) {
      throw const FormatException('Session-state metadata must be an object.');
    }
    final reservationMarkerAdjacent = map['reservation_marker_adjacent'];
    if (reservationMarkerAdjacent != null &&
        reservationMarkerAdjacent is! bool) {
      throw const FormatException(
        'Session-state reservation_marker_adjacent must be a boolean.',
      );
    }
    return SessionStateLease(
      id: _requiredString(map, 'id'),
      workflowId: _requiredString(map, 'workflow_id'),
      workflowVersion: _requiredInt(map, 'workflow_version'),
      logicalResourceKey: _requiredString(map, 'logical_resource_key'),
      namespace: SessionStateNamespace.fromLabel(
        _requiredString(map, 'namespace'),
      ),
      retention: SessionStateRetention.fromLabel(
        _requiredString(map, 'retention'),
      ),
      processScope: LeaseScope.fromLabel(_requiredString(map, 'process_scope')),
      ownership: SessionStateOwnership.fromLabel(
        _requiredString(map, 'ownership'),
      ),
      acquisitionMode: SessionStateAcquisitionMode.fromLabel(
        _requiredString(map, 'acquisition_mode'),
      ),
      phase: SessionStatePhase.fromLabel(_requiredString(map, 'phase')),
      resourceKind: SessionStateResourceKind.fromLabel(
        _requiredString(map, 'resource_kind'),
      ),
      rootPath: _requiredString(map, 'root_path'),
      relativePath: _requiredString(map, 'relative_path'),
      markerNonce: _requiredString(map, 'marker_nonce'),
      hostId: _requiredString(map, 'host_id'),
      bootId: _requiredString(map, 'boot_id'),
      ownerProject: _requiredString(map, 'owner_project'),
      ownerPid: _requiredInt(map, 'owner_pid'),
      ownerPidToken: _requiredString(map, 'owner_pid_token'),
      processLeaseId: map['process_lease_id'] as String?,
      processPid: map['process_pid'] as int?,
      processPidToken: map['process_pid_token'] as String?,
      quarantineRelativePath: map['quarantine_relative_path'] as String?,
      createdAt: DateTime.parse(_requiredString(map, 'created_at')).toUtc(),
      updatedAt: DateTime.parse(_requiredString(map, 'updated_at')).toUtc(),
      attemptCount: _requiredInt(map, 'attempt_count'),
      lastError: map['last_error'] as String?,
      completedCleanupSteps:
          (map['completed_cleanup_steps'] as List<Object?>?)?.cast<String>() ??
          const [],
      metadata: metadataValue.cast<String, Object?>(),
      generation: _requiredInt(map, 'generation'),
      reservationMarkerAdjacent: reservationMarkerAdjacent == true,
    );
  }

  /// Current record schema.
  static const schemaVersion = 1;

  /// Core-generated random acquisition id; never derived from user input.
  final String id;

  /// Stable workflow identity and version.
  final String workflowId;
  final int workflowVersion;

  /// Provider-derived identity for the underlying resource.
  final String logicalResourceKey;

  /// Resource ownership namespace and retention are deliberately independent.
  final SessionStateNamespace namespace;
  final SessionStateRetention retention;
  final LeaseScope processScope;
  final SessionStateOwnership ownership;
  final SessionStateAcquisitionMode acquisitionMode;
  final SessionStatePhase phase;
  final SessionStateResourceKind resourceKind;

  /// Canonical root plus a relative path. Never trust this pair without
  /// verifying the registered root, marker and containment again.
  final String rootPath;
  final String relativePath;

  /// Random marker value created by Oka for Oka-owned filesystem resources.
  final String markerNonce;

  /// Oka host and boot identity. A mismatch means retain and report.
  final String hostId;
  final String bootId;

  /// Owning project and manager process snapshot.
  final String ownerProject;
  final int ownerPid;
  final String ownerPidToken;

  /// Optional process lease reference and independent process snapshot.
  final String? processLeaseId;
  final int? processPid;
  final String? processPidToken;
  final String? quarantineRelativePath;

  /// Whether this lease promises a separately managed process identity.
  ///
  /// A process-lease reference is itself an expectation that a corresponding
  /// PID/token snapshot exists, even when older or damaged metadata omitted
  /// `process_snapshot_required`.
  bool get requiresProcessSnapshot =>
      metadata['process_snapshot_required'] == true || processLeaseId != null;

  /// Whether the associated process snapshot is complete enough to verify.
  bool get hasCompleteProcessSnapshot =>
      processPid != null &&
      processPid! > 0 &&
      processPidToken != null &&
      processPidToken!.isNotEmpty;

  final DateTime createdAt;
  final DateTime updatedAt;
  final int attemptCount;
  final String? lastError;
  final List<String> completedCleanupSteps;

  /// Provider metadata must be non-secret and JSON-serializable.
  final Map<String, Object?> metadata;

  /// Monotonic update generation used by the registry CAS boundary.
  final int generation;

  /// Whether this lease uses the adjacent reservation marker layout.
  ///
  /// False is the legacy project-cache layout, retained for old records.
  final bool reservationMarkerAdjacent;

  /// Marker that proves reservation preceded resource creation.
  String get reservationMarkerPath {
    if (!reservationMarkerAdjacent) {
      return p.join(
        rootPath,
        '.oka_cache',
        'session-state-reservations',
        '$id.json',
      );
    }
    final parent = p.posix.dirname(relativePath);
    return p.joinAll([
      rootPath,
      if (parent != '.') parent,
      '.oka-session-state-reservations',
      '$id.json',
    ]);
  }

  SessionStateLease copyWith({
    SessionStatePhase? phase,
    SessionStateAcquisitionMode? acquisitionMode,
    String? ownerProject,
    int? ownerPid,
    String? ownerPidToken,
    String? processLeaseId,
    int? processPid,
    String? processPidToken,
    String? quarantineRelativePath,
    DateTime? updatedAt,
    String? hostId,
    String? bootId,
    int? attemptCount,
    String? lastError,
    Map<String, Object?>? metadata,
    int? generation,
    bool? reservationMarkerAdjacent,
    bool clearProcessIdentity = false,
    bool clearLastError = false,
    List<String>? completedCleanupSteps,
  }) => SessionStateLease(
    id: id,
    workflowId: workflowId,
    workflowVersion: workflowVersion,
    logicalResourceKey: logicalResourceKey,
    namespace: namespace,
    retention: retention,
    processScope: processScope,
    ownership: ownership,
    acquisitionMode: acquisitionMode ?? this.acquisitionMode,
    phase: phase ?? this.phase,
    resourceKind: resourceKind,
    rootPath: rootPath,
    relativePath: relativePath,
    markerNonce: markerNonce,
    hostId: hostId ?? this.hostId,
    bootId: bootId ?? this.bootId,
    ownerProject: ownerProject ?? this.ownerProject,
    ownerPid: ownerPid ?? this.ownerPid,
    ownerPidToken: ownerPidToken ?? this.ownerPidToken,
    processLeaseId:
        processLeaseId ?? (clearProcessIdentity ? null : this.processLeaseId),
    processPid: processPid ?? (clearProcessIdentity ? null : this.processPid),
    processPidToken:
        processPidToken ?? (clearProcessIdentity ? null : this.processPidToken),
    quarantineRelativePath:
        quarantineRelativePath ?? this.quarantineRelativePath,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    attemptCount: attemptCount ?? this.attemptCount,
    lastError: lastError ?? (clearLastError ? null : this.lastError),
    completedCleanupSteps: completedCleanupSteps ?? this.completedCleanupSteps,
    metadata: metadata ?? this.metadata,
    generation: generation ?? this.generation,
    reservationMarkerAdjacent:
        reservationMarkerAdjacent ?? this.reservationMarkerAdjacent,
  );

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'id': id,
    'workflow_id': workflowId,
    'workflow_version': workflowVersion,
    'logical_resource_key': logicalResourceKey,
    'namespace': namespace.label,
    'retention': retention.label,
    'process_scope': processScope.label,
    'ownership': ownership.label,
    'acquisition_mode': acquisitionMode.label,
    'phase': phase.label,
    'resource_kind': resourceKind.label,
    'root_path': rootPath,
    'relative_path': relativePath,
    'marker_nonce': markerNonce,
    'host_id': hostId,
    'boot_id': bootId,
    'owner_project': ownerProject,
    'owner_pid': ownerPid,
    'owner_pid_token': ownerPidToken,
    if (processLeaseId != null) 'process_lease_id': processLeaseId,
    if (processPid != null) 'process_pid': processPid,
    if (processPidToken != null) 'process_pid_token': processPidToken,
    if (quarantineRelativePath != null)
      'quarantine_relative_path': quarantineRelativePath,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'attempt_count': attemptCount,
    if (lastError != null) 'last_error': lastError,
    'completed_cleanup_steps': completedCleanupSteps,
    'metadata': metadata,
    'generation': generation,
    if (reservationMarkerAdjacent) 'reservation_marker_adjacent': true,
  };

  static String _requiredString(
    final Map<String, Object?> map,
    final String key,
  ) {
    final value = map[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Session-state field "$key" must be a string.');
    }
    return value;
  }

  static int _requiredInt(final Map<String, Object?> map, final String key) {
    final value = map[key];
    if (value is! int) {
      throw FormatException('Session-state field "$key" must be an integer.');
    }
    return value;
  }
}

/// Structured result from one state inspector. Only [unused] is affirmative;
/// [busy] and [unknown] both block cleanup.
enum SessionStateUse { unused, busy, unknown }

/// One human- and machine-readable safety observation.
@immutable
final class SessionStateFinding {
  const SessionStateFinding({
    required this.inspectorId,
    required this.use,
    required this.reason,
    this.details = const {},
  });

  final String inspectorId;
  final SessionStateUse use;
  final String reason;
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => {
    'inspector_id': inspectorId,
    'use': use.name,
    'reason': reason,
    'details': details,
  };
}

/// Typed planning value. [handle] is kept in memory and never serialized.
@immutable
final class SessionStatePlan<H> {
  const SessionStatePlan({
    required this.logicalResourceKey,
    required this.namespace,
    required this.retention,
    required this.processScope,
    required this.ownership,
    required this.acquisitionMode,
    required this.resourceKind,
    required this.rootPath,
    required this.relativePath,
    required this.handle,
    this.metadata = const {},
  });

  final String logicalResourceKey;
  final SessionStateNamespace namespace;
  final SessionStateRetention retention;
  final LeaseScope processScope;
  final SessionStateOwnership ownership;
  final SessionStateAcquisitionMode acquisitionMode;
  final SessionStateResourceKind resourceKind;
  final String rootPath;
  final String relativePath;
  final H handle;
  final Map<String, Object?> metadata;

  /// Returns validation problems for path identity and lifetime ordering.
  List<String> validate() {
    final issues = <String>[];
    if (logicalResourceKey.trim().isEmpty || logicalResourceKey.length > 1024) {
      issues.add('logical resource key must contain 1–1024 characters.');
    }
    if (retention.index < processScope.index) {
      issues.add(
        'state retention "${retention.label}" is shorter than process '
        'scope "${processScope.label}".',
      );
    }
    if (resourceKind == SessionStateResourceKind.directory) {
      if (rootPath.isEmpty) issues.add('directory state needs a root path.');
      if (relativePath.isEmpty ||
          relativePath == '.' ||
          relativePath == '..' ||
          relativePath.startsWith('/') ||
          relativePath.contains(r'\') ||
          relativePath.split('/').contains('..') ||
          p.posix.isAbsolute(relativePath)) {
        issues.add(
          'directory state path must be a safe relative path without traversal.',
        );
      }
    }
    if (ownership == SessionStateOwnership.caller &&
        acquisitionMode != SessionStateAcquisitionMode.borrowed) {
      issues.add('caller-owned resources must use borrowed acquisition mode.');
    }
    if (acquisitionMode == SessionStateAcquisitionMode.borrowed &&
        ownership == SessionStateOwnership.oka) {
      issues.add('borrowed resources cannot be marked Oka-owned.');
    }
    if (resourceKind == SessionStateResourceKind.opaque &&
        retention != SessionStateRetention.persistent) {
      issues.add(
        'opaque state must be retained until explicit provider cleanup.',
      );
    }
    return List.unmodifiable(issues);
  }
}

/// Inputs to a pure planner.
@immutable
final class SessionStateRequest {
  const SessionStateRequest({
    required this.projectPath,
    required this.sessionName,
    this.metadata = const {},
  });

  final String projectPath;
  final String sessionName;
  final Map<String, Object?> metadata;
}

/// Produces a plan without creating or mutating a resource.
abstract interface class SessionStatePlanner<H> {
  String get id;

  SessionStatePlan<H> plan(SessionStateRequest request);
}

/// A read-only source for reconstructing a typed handle from a durable lease.
abstract interface class SessionStateSource<H> {
  String get id;

  Future<H> restore(SessionStateLease lease);
}

/// Typed input shared by workflow phases.
final class SessionStateContext<H> {
  SessionStateContext({
    required this.handle,
    required this.lease,
    final Map<String, Object?> artifacts = const {},
  }) : artifacts = Map.of(artifacts);

  final H handle;
  final SessionStateLease lease;
  final Map<String, Object?> artifacts;
}

/// One idempotent provisioning phase.
abstract interface class SessionStateProvisionStep<H> {
  String get id;
  Set<Artifact<Object>> get requires;
  Set<Artifact<Object>> get provides;

  Future<void> run(SessionStateContext<H> context);
}

/// Read-only activity and ownership evidence.
abstract interface class SessionStateInspector<H> {
  String get id;

  Future<SessionStateFinding> inspect(SessionStateContext<H> context);
}

/// Cleanup preparation phase. Filesystem deletion remains core-owned.
abstract interface class SessionStateCleanupStep<H> {
  String get id;

  Future<void> prepare(SessionStateContext<H> context);
}

/// A typed workflow restored from a durable lease for inspection, provisioning
/// and cleanup preparation.
final class SessionStateWorkflowSession {
  const SessionStateWorkflowSession({
    required this._inspect,
    required this.cleanupStepIds,
    required this._prepareCleanupStep,
    required this._provision,
  });

  final Future<List<SessionStateFinding>> Function(SessionStateLease) _inspect;
  final Future<void> Function(SessionStateLease, String) _prepareCleanupStep;
  final Future<void> Function(SessionStateLease) _provision;
  final List<String> cleanupStepIds;

  /// Internal manager operation; callers must hold the resource lock and have
  /// passed the lease's safety checks before invoking provisioning.
  @internal
  Future<void> provision(final SessionStateLease lease) => _provision(lease);

  Future<List<SessionStateFinding>> inspect(final SessionStateLease lease) =>
      _inspect(lease);

  Future<void> prepareCleanupStep(
    final SessionStateLease lease,
    final String stepId,
  ) => _prepareCleanupStep(lease, stepId);
}

/// Immutable composition of plan, typed source, provision, inspection and
/// cleanup components. [id] is a stable, globally unique provider identifier;
/// packages and projects must not reuse another workflow's ID because
/// out-of-project CLI fallback can only compose first-party workflows.
@immutable
final class SessionStateWorkflow<H> {
  const SessionStateWorkflow({
    required this.id,
    required this.version,
    required this.plan,
    required this.source,
    this.provision = const [],
    this.inspectors = const [],
    this.reuseInspectors,
    this.cleanup = const [],
    this.inspectionTimeout = const Duration(seconds: 10),
    this.cleanupTimeout = const Duration(seconds: 30),
  });

  /// Maximum wait for restoring handles and running read-only inspectors.
  final Duration inspectionTimeout;

  /// Maximum wait for one cleanup preparation step.
  ///
  /// A timeout does not cancel provider I/O. The reconciler records itself as
  /// the lease owner while cleanup runs, so another reconciliation retains
  /// the resource until this process exits.
  final Duration cleanupTimeout;

  /// Stable, globally unique provider identifier; do not reuse another
  /// provider's ID. Increment [version] when persisted lease semantics change.
  final String id;
  final int version;
  final SessionStatePlanner<H> plan;
  final SessionStateSource<H> source;
  final List<SessionStateProvisionStep<H>> provision;
  final List<SessionStateInspector<H>> inspectors;

  /// Inspectors used to prove that managed state is safe to reacquire.
  ///
  /// When omitted, [inspectors] are used for both reuse checks and
  /// reconciliation. This can differ when active-resource evidence is enough
  /// to block cleanup but is not relevant to launching another consumer.
  final List<SessionStateInspector<H>>? reuseInspectors;
  final List<SessionStateCleanupStep<H>> cleanup;

  /// Restores a typed handle once and exposes safe, type-erased operations to
  /// the registry-driven reconciler.
  Future<SessionStateWorkflowSession> restoreSession(
    final SessionStateLease lease, {
    final bool forReuse = false,
  }) async {
    final handle = await source.restore(lease).timeout(inspectionTimeout);
    final inspectorsForSession = forReuse
        ? reuseInspectors ?? inspectors
        : inspectors;
    return SessionStateWorkflowSession(
      inspect: (final currentLease) async {
        final context = SessionStateContext<H>(
          handle: handle,
          lease: currentLease,
        );
        final findings = <SessionStateFinding>[];
        for (final inspector in inspectorsForSession) {
          try {
            findings.add(
              await inspector.inspect(context).timeout(inspectionTimeout),
            );
          } on TimeoutException {
            findings.add(
              SessionStateFinding(
                inspectorId: inspector.id,
                use: SessionStateUse.unknown,
                reason:
                    'inspector exceeded '
                    '${inspectionTimeout.inMilliseconds}ms; state is retained.',
              ),
            );
          } on Object catch (error) {
            findings.add(
              SessionStateFinding(
                inspectorId: inspector.id,
                use: SessionStateUse.unknown,
                reason: 'inspector failed; state is retained: $error',
              ),
            );
          }
        }
        return List.unmodifiable(findings);
      },
      provision: (final currentLease) async {
        final context = SessionStateContext<H>(
          handle: handle,
          lease: currentLease,
        );
        for (final step in provision) {
          for (final artifact in step.requires) {
            if (!context.artifacts.containsKey(artifact.id) ||
                !artifact.accepts(context.artifacts[artifact.id])) {
              throw StateError(
                'Provision step "${step.id}" requires artifact '
                '"${artifact.id}" before it is available.',
              );
            }
          }
          await step.run(context);
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
      },
      cleanupStepIds: cleanup.map((final step) => step.id).toList(),
      prepareCleanupStep: (final currentLease, final stepId) async {
        final context = SessionStateContext<H>(
          handle: handle,
          lease: currentLease,
        );
        final step = cleanup.firstWhere((final item) => item.id == stepId);
        await step.prepare(context).timeout(cleanupTimeout);
      },
    );
  }

  /// Reports composition errors before any resource side effect.
  List<String> validate() {
    final issues = <String>[];
    if (!_validStableId(id)) issues.add('workflow id "$id" is not path-safe.');
    if (version < 1) issues.add('workflow "$id" version must be positive.');
    if (inspectionTimeout <= Duration.zero) {
      issues.add('workflow "$id" inspection timeout must be positive.');
    }
    if (cleanupTimeout <= Duration.zero) {
      issues.add('workflow "$id" cleanup timeout must be positive.');
    }
    final plannerId = plan.id;
    if (!_validStableId(plannerId)) {
      issues.add('planner id "$plannerId" is not path-safe.');
    }
    final sourceId = source.id;
    if (!_validStableId(sourceId)) {
      issues.add('source id "$sourceId" is not path-safe.');
    }
    final ids = <String, String>{};
    void claim(final String value, final String phase) {
      if (!_validStableId(value)) {
        issues.add('$phase id "$value" is not path-safe.');
      }
      final previous = ids[value];
      if (previous != null) {
        issues.add(
          'component id "$value" is duplicated in $previous and $phase.',
        );
      } else {
        ids[value] = phase;
      }
    }

    claim(id, 'workflow');
    claim(plannerId, 'planner');
    claim(sourceId, 'source');
    for (final inspector in inspectors) {
      claim(inspector.id, 'inspector');
    }
    final reuseInspectorsToValidate = reuseInspectors;
    if (reuseInspectorsToValidate != null) {
      for (final inspector in reuseInspectorsToValidate) {
        if (inspectors.any((final item) => identical(item, inspector))) {
          continue;
        }
        claim(inspector.id, 'reuse inspector');
      }
    }
    for (final step in provision) {
      claim(step.id, 'provision');
    }
    for (final step in cleanup) {
      claim(step.id, 'cleanup');
    }

    final provided = <String, Artifact<Object>>{};
    for (final step in provision) {
      for (final requirement in step.requires) {
        final producer = provided[requirement.id];
        if (producer == null) {
          issues.add(
            'provision "${step.id}" requires "${requirement.id}" '
            'before any step provides it.',
          );
        } else if (producer.runtimeType != requirement.runtimeType) {
          issues.add(
            'provision "${step.id}" requires "${requirement.id}" with a '
            'different artifact type than its provider.',
          );
        }
      }
      for (final artifact in step.provides) {
        if (provided.containsKey(artifact.id)) {
          issues.add(
            'artifact "${artifact.id}" is provided more than once in '
            'session-state workflow "$id".',
          );
        } else {
          provided[artifact.id] = artifact;
        }
      }
    }
    if (inspectors.isEmpty) {
      issues.add('workflow "$id" must provide at least one safety inspector.');
    }
    return List.unmodifiable(issues);
  }
}

bool _validStableId(final String value) =>
    RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$').hasMatch(value) &&
    value != '.' &&
    value != '..';

/// Marker stored inside an Oka-created directory resource.
String sessionStateOwnershipMarkerPath(final String resourcePath) =>
    p.join(resourcePath, '.oka-state-owner.json');
