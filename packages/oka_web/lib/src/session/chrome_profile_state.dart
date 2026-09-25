/// First-party managed state workflow for Chromium user-data directories.
library;

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// A Chrome-family user-data directory handle. It is never serialized.
@immutable
final class ChromeProfileHandle {
  const ChromeProfileHandle(this.path);

  final String path;
}

/// Pure planner for project-scoped Chromium user-data directories.
///
/// The caller supplies an existing project root and a safe relative profile
/// path in [SessionStateRequest.metadata]. The durable lease, not this
/// temporary request, remains the source of truth during recovery.
final class ChromeProfilePlanner
    implements SessionStatePlanner<ChromeProfileHandle> {
  const ChromeProfilePlanner();

  @override
  String get id => 'chrome-profile-plan';

  @override
  SessionStatePlan<ChromeProfileHandle> plan(
    final SessionStateRequest request,
  ) {
    final rootPath = request.metadata['state_root'];
    final relativePath = request.metadata['relative_path'];
    if (rootPath is! String || rootPath.isEmpty) {
      throw ArgumentError('Chrome profile request needs a state_root.');
    }
    if (relativePath is! String || relativePath.isEmpty) {
      throw ArgumentError('Chrome profile request needs a relative_path.');
    }
    final retentionValue =
        request.metadata['state_retention'] ??
        SessionStateRetention.ephemeral.label;
    final processScopeValue =
        request.metadata['process_scope'] ?? LeaseScope.ephemeral.label;
    final ownershipValue =
        request.metadata['state_ownership'] ?? SessionStateOwnership.oka.label;
    final acquisitionModeValue =
        request.metadata['acquisition_mode'] ??
        SessionStateAcquisitionMode.created.label;
    if (retentionValue is! String ||
        processScopeValue is! String ||
        ownershipValue is! String ||
        acquisitionModeValue is! String) {
      throw ArgumentError(
        'Chrome profile ownership and lifecycle values must be strings.',
      );
    }
    final retention = SessionStateRetention.fromLabel(retentionValue);
    final processScope = LeaseScope.fromLabel(processScopeValue);
    final ownership = SessionStateOwnership.fromLabel(ownershipValue);
    final acquisitionMode = SessionStateAcquisitionMode.fromLabel(
      acquisitionModeValue,
    );

    return SessionStatePlan(
      logicalResourceKey:
          'chrome-profile:${request.projectPath}:${request.sessionName}',
      namespace: SessionStateNamespace.project,
      retention: retention,
      processScope: processScope,
      ownership: ownership,
      acquisitionMode: acquisitionMode,
      resourceKind: SessionStateResourceKind.directory,
      rootPath: rootPath,
      relativePath: relativePath,
      handle: ChromeProfileHandle(p.join(rootPath, relativePath)),
      metadata: {
        'browser_family': 'chromium',
        'session_name': request.sessionName,
        'process_snapshot_required':
            request.metadata['process_snapshot_required'] == true,
      },
    );
  }
}

/// Restores a Chrome profile handle only from a validated durable lease.
final class ChromeProfileSource
    implements SessionStateSource<ChromeProfileHandle> {
  const ChromeProfileSource();

  @override
  String get id => 'chrome-profile-source';

  @override
  Future<ChromeProfileHandle> restore(final SessionStateLease lease) async =>
      ChromeProfileHandle(p.join(lease.rootPath, lease.relativePath));
}

/// Confirms that core created the private profile directory before provisioning.
final class VerifyChromeProfileCreated
    implements SessionStateProvisionStep<ChromeProfileHandle> {
  const VerifyChromeProfileCreated();

  @override
  String get id => 'chrome-profile-verify-created';

  @override
  Set<Artifact<Object>> get requires => const {};

  @override
  Set<Artifact<Object>> get provides => const {};

  @override
  Future<void> run(
    final SessionStateContext<ChromeProfileHandle> context,
  ) async {
    if (await FileSystemEntity.type(context.handle.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'Core-managed profile directory is missing or not a real directory.',
        context.handle.path,
      );
    }
  }
}

/// Vetoes cleanup while Chromium's documented profile singleton is present
/// or the browser's use of the profile cannot be positively ruled out.
final class ChromeProfileUseInspector
    implements SessionStateInspector<ChromeProfileHandle> {
  const ChromeProfileUseInspector({
    this.liveness = const HostProcessLiveness(),
  });

  final ProcessLiveness liveness;

  @override
  String get id => 'chrome-profile-singleton';

  @override
  Future<SessionStateFinding> inspect(
    final SessionStateContext<ChromeProfileHandle> context,
  ) => _inspectChromeProfileSingleton(
    context,
    liveness: liveness,
    inspectorId: id,
    allowLaunchWithDeadOwner: false,
  );
}

/// Allows a new Chrome launch to reuse a profile only when a valid local
/// singleton owner matches the durable process snapshot and has exited. This
/// is deliberately separate from [ChromeProfileUseInspector]: that match may
/// allow launch but never proves cleanup can delete the profile.
final class ChromeProfileLaunchInspector
    implements SessionStateInspector<ChromeProfileHandle> {
  const ChromeProfileLaunchInspector({
    this.liveness = const HostProcessLiveness(),
  });

  final ProcessLiveness liveness;

  @override
  String get id => 'chrome-profile-launch-singleton';

  @override
  Future<SessionStateFinding> inspect(
    final SessionStateContext<ChromeProfileHandle> context,
  ) => _inspectChromeProfileSingleton(
    context,
    liveness: liveness,
    inspectorId: id,
    allowLaunchWithDeadOwner: true,
  );
}

Future<SessionStateFinding> _inspectChromeProfileSingleton(
  final SessionStateContext<ChromeProfileHandle> context, {
  required final ProcessLiveness liveness,
  required final String inspectorId,
  required final bool allowLaunchWithDeadOwner,
}) async {
  final lockPath = p.join(context.handle.path, 'SingletonLock');
  final type = await FileSystemEntity.type(lockPath, followLinks: false);
  if (!Platform.isLinux && !Platform.isMacOS) {
    final firstWindowsLaunch =
        Platform.isWindows &&
        allowLaunchWithDeadOwner &&
        context.lease.acquisitionMode == SessionStateAcquisitionMode.created &&
        context.lease.ownerPid == pid &&
        context.lease.processPid == null &&
        context.lease.processLeaseId == null &&
        context.lease.metadata['process_snapshot_required'] == false;
    if (firstWindowsLaunch && type == FileSystemEntityType.notFound) {
      return SessionStateFinding(
        inspectorId: inspectorId,
        use: SessionStateUse.unused,
        reason:
            'New Oka-created profile has no prior process snapshot or '
            'SingletonLock; this first launch does not infer cleanup safety.',
      );
    }
    return SessionStateFinding(
      inspectorId: inspectorId,
      use: SessionStateUse.unknown,
      reason: 'SingletonLock semantics are unverified on this host OS.',
    );
  }
  if (type == FileSystemEntityType.notFound) {
    return SessionStateFinding(
      inspectorId: inspectorId,
      use: SessionStateUse.unused,
      reason: 'Chromium SingletonLock is absent.',
    );
  }
  if (type != FileSystemEntityType.link) {
    return SessionStateFinding(
      inspectorId: inspectorId,
      use: SessionStateUse.unknown,
      reason: 'SingletonLock exists but is not a recognized symlink.',
      details: {'path': lockPath, 'file_type': '$type'},
    );
  }

  final target = await Link(lockPath).target();
  final separator = target.lastIndexOf('-');
  if (separator <= 0 || separator == target.length - 1) {
    return SessionStateFinding(
      inspectorId: inspectorId,
      use: SessionStateUse.unknown,
      reason: 'SingletonLock target has an unrecognized host/PID format.',
      details: {'lock_target': target},
    );
  }
  final host = target.substring(0, separator);
  final singletonPid = int.tryParse(target.substring(separator + 1));
  if (singletonPid == null ||
      singletonPid <= 0 ||
      host.toLowerCase() != Platform.localHostname.toLowerCase()) {
    return SessionStateFinding(
      inspectorId: inspectorId,
      use: SessionStateUse.unknown,
      reason: 'SingletonLock belongs to another host or has an invalid PID.',
      details: {'lock_target': target},
    );
  }
  try {
    if (await liveness.isAlive(singletonPid)) {
      return SessionStateFinding(
        inspectorId: inspectorId,
        use: SessionStateUse.busy,
        reason: 'SingletonLock owner process $singletonPid is still alive.',
        details: {'pid': singletonPid},
      );
    }
    if (allowLaunchWithDeadOwner &&
        context.lease.processPid == singletonPid &&
        context.lease.processPidToken != null) {
      return SessionStateFinding(
        inspectorId: inspectorId,
        use: SessionStateUse.unused,
        reason:
            'SingletonLock owner process $singletonPid is stopped; a new '
            'browser launch may proceed, but this is not cleanup evidence.',
        details: {'pid': singletonPid, 'authority': 'launch-only'},
      );
    }
    return SessionStateFinding(
      inspectorId: inspectorId,
      use: SessionStateUse.unknown,
      reason:
          'SingletonLock owner process $singletonPid is stopped, but a present lock '
          'does not match a verified process snapshot for launch or prove '
          'that no detached child or concurrent opener uses the profile; '
          'cleanup is not authorized.',
      details: {'pid': singletonPid},
    );
  } on Object catch (error) {
    return SessionStateFinding(
      inspectorId: inspectorId,
      use: SessionStateUse.unknown,
      reason: 'Could not verify SingletonLock owner process: $error',
      details: {'pid': singletonPid},
    );
  }
}

/// Default composable workflow used by [ChromeSessionTarget].
///
/// Custom browser integrations can replace or extend any phase while keeping
/// the same core lease and safety rules.
const chromeProfileStateWorkflow = SessionStateWorkflow<ChromeProfileHandle>(
  id: 'oka.chrome-profile',
  version: 1,
  plan: ChromeProfilePlanner(),
  source: ChromeProfileSource(),
  provision: [VerifyChromeProfileCreated()],
  inspectors: [ChromeProfileUseInspector()],
  reuseInspectors: [ChromeProfileLaunchInspector()],
);
