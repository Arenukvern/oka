/// A browser session over a declared project target.
///
/// This is the preview contract after ADR 0020: a *URL a browser window can
/// navigate to*, and the ownership of the process that serves it.
///
/// Laws:
///
/// * a target somebody else already serves is **borrowed** — this session
///   never signals it, not on attach, not on detach;
/// * a process this session spawned is **owned** — it is stopped through
///   oka's identity-gated tree stop, and only a verified stop drops its
///   lease record;
/// * a failed attach keeps the last known good target, so a broken change
///   leaves the browser window on the last working thing.
///
/// The session owns the *process*, not the browser window. The window's own
/// lifetime belongs to the surface lane, which applies the same ownership
/// law to the value this session exposes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../oka_core.dart';
import 'project_operation_profile.dart';

/// Who owns the process behind a browser target.
enum ProjectSessionOwnership {
  /// This session spawned the process; it may stop it.
  owned,

  /// Somebody else owns the process, or the target is remote; this session
  /// never signals it.
  borrowed,
}

/// The result of one attach or detach.
final class ProjectBrowserSessionOutcome {
  /// Describes one result.
  const ProjectBrowserSessionOutcome({
    required this.ok,
    required this.url,
    this.ownership,
    this.error,
    this.detail,
    this.exitCode,
    this.stderr = '',
    this.retainedLastKnownGood = false,
    this.pid,
  });

  /// Whether the session reached the requested state.
  final bool ok;

  /// The URL a browser window navigates to.
  final Uri? url;

  /// Who owns the process behind the target.
  final ProjectSessionOwnership? ownership;

  /// The named failure, when the request failed.
  final String? error;

  /// The detail of the named failure.
  final String? detail;

  /// The exit code of a serve process that ended before it was ready.
  final int? exitCode;

  /// The tail of the serve process' standard error.
  final String stderr;

  /// Whether the last known good target was kept after a failure.
  final bool retainedLastKnownGood;

  /// The pid of the process this session spawned.
  final int? pid;

  /// The evidence projection of this result.
  Map<String, Object?> toJson() => {
    'ok': ok,
    'url': url?.toString(),
    if (ownership != null) 'ownership': ownership!.name,
    if (error != null) 'error': error,
    if (detail != null) 'detail': detail,
    if (exitCode != null) 'exitCode': exitCode,
    if (stderr.isNotEmpty) 'stderr': stderr,
    'retainedLastKnownGood': retainedLastKnownGood,
    if (pid != null) 'pid': pid,
  };
}

/// A browser session over a declared project target.
final class ProjectBrowserSession {
  /// Creates a session.
  ProjectBrowserSession({
    required this.profile,
    required this.workspace,
    required this.leaseRegistry,
    this.leaseId,
    ProcessLiveness? liveness,
    ProcessTreeProbe? treeProbe,
    this.readinessTimeout = const Duration(seconds: 30),
    this.stopGrace = const Duration(seconds: 3),
  }) : liveness = liveness ?? const HostProcessLiveness(),
       treeProbe = treeProbe ?? const HostProcessTreeProbe();

  /// The declared commands of the project behind the target.
  final ProjectOperationProfile profile;

  /// The owner project root.
  final Directory workspace;

  /// The lease registry of this session's processes.
  final ProcessLeaseRegistry leaseRegistry;

  /// The lease id of the serve process.
  final String? leaseId;

  /// The liveness seam.
  final ProcessLiveness liveness;

  /// The process-tree seam.
  final ProcessTreeProbe treeProbe;

  /// How long a spawned process may take to become ready.
  final Duration readinessTimeout;

  /// The grace period of the teardown ladder.
  final Duration stopGrace;

  Uri? _url;
  ProjectSessionOwnership? _ownership;
  int? _pid;
  String? _identityToken;
  bool _attached = false;
  ProjectBrowserSessionOutcome _lastOutcome =
      const ProjectBrowserSessionOutcome(
        ok: false,
        url: null,
        error: 'project_session_not_attached',
      );

  /// The URL a browser window navigates to, when the session is attached.
  Uri? get url => _url;

  /// Who owns the process behind [url].
  ProjectSessionOwnership? get ownership => _ownership;

  /// Whether the session is attached to a target.
  bool get attached => _attached;

  /// The result of the last attach or detach.
  ProjectBrowserSessionOutcome get lastOutcome => _lastOutcome;

  /// The lease id of this session, derived from the profile and the
  /// workspace when the caller did not name one.
  String get effectiveLeaseId =>
      leaseId ?? ProjectBrowserSession.leaseIdFor(profile.id, workspace.path);

  /// The deterministic lease id of a profile/workspace pair.
  static String leaseIdFor(String profileId, String workspacePath) {
    final key = sha256
        .convert(utf8.encode('$profileId|$workspacePath'))
        .toString();
    return 'project-session-${key.substring(0, 24)}';
  }

  /// Attaches the session to a target.
  ///
  /// [url] overrides the declared endpoint; without it the profile's serve
  /// endpoint is used. [replace] restarts an owned session instead of
  /// returning the current one.
  Future<ProjectBrowserSessionOutcome> attach({
    Uri? url,
    bool replace = false,
  }) async {
    if (_attached && !replace) {
      return _record(
        ProjectBrowserSessionOutcome(
          ok: true,
          url: _url,
          ownership: _ownership,
          pid: _pid,
        ),
      );
    }
    final target = url ?? _declaredTarget();
    if (target == null) {
      return _record(
        _failure(
          'project_browser_target_unavailable',
          'the profile "${profile.id}" declares no endpoint and no url was '
              'given',
        ),
      );
    }
    if (replace && _ownership == ProjectSessionOwnership.owned) {
      await _stopOwned();
    }
    if (!_isLoopback(target)) {
      // A remote target is somebody else's: navigate to it, own nothing,
      // probe nothing.
      return _record(
        _borrowed(target, detail: 'remote target; not owned and not probed'),
      );
    }
    if (await _isReachable(target)) {
      return _record(_borrowed(target, detail: 'endpoint already served'));
    }
    final operation = profile.operation(ProjectOperationKind.serve);
    if (operation == null) {
      return _record(
        _failure(
          'project_browser_endpoint_unreachable',
          'no serve operation is declared for the profile "${profile.id}"',
        ),
      );
    }
    return _record(await _spawnAndAttach(operation, target));
  }

  /// Releases the session.
  ///
  /// An owned process is stopped through the identity-gated tree stop; a
  /// borrowed target is never signalled.
  Future<ProjectBrowserSessionOutcome> detach() async {
    if (_ownership == ProjectSessionOwnership.owned) {
      await _stopOwned();
      return _record(
        ProjectBrowserSessionOutcome(
          ok: true,
          url: _url,
          ownership: _ownership,
        ),
      );
    }
    _attached = false;
    return _record(
      ProjectBrowserSessionOutcome(
        ok: true,
        url: _url,
        ownership: _ownership,
        detail: 'borrowed target left untouched',
      ),
    );
  }

  Uri? _declaredTarget() {
    final operation = profile.operation(ProjectOperationKind.serve);
    final endpoint = operation?.endpoint;
    if (endpoint == null) return null;
    return endpoint.toUri();
  }

  bool _isLoopback(Uri target) {
    final host = target.host;
    return host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host == '[::1]';
  }

  Future<bool> _isReachable(Uri target) async {
    if (target.port == 0) return false;
    try {
      final socket = await Socket.connect(
        target.host,
        target.port,
        timeout: const Duration(milliseconds: 300),
      );
      socket.destroy();
      return true;
    } on Object {
      return false;
    }
  }

  ProjectBrowserSessionOutcome _borrowed(Uri target, {String? detail}) {
    _url = target;
    _ownership = ProjectSessionOwnership.borrowed;
    _attached = true;
    return ProjectBrowserSessionOutcome(
      ok: true,
      url: target,
      ownership: ProjectSessionOwnership.borrowed,
      detail: detail,
    );
  }

  Future<ProjectBrowserSessionOutcome> _spawnAndAttach(
    ProjectOperation operation,
    Uri target,
  ) async {
    final directory = _resolveDirectory(operation.command.workingDirectory);
    final Process process;
    try {
      process = await Process.start(
        operation.command.executable,
        operation.command.arguments,
        workingDirectory: directory.path,
        environment: operation.command.environment.isEmpty
            ? null
            : operation.command.environment,
      );
    } on Object catch (error) {
      return _failure('project_session_spawn_failed', '$error');
    }
    String? token;
    try {
      token = await liveness.identityToken(process.pid);
    } on Object {
      token = null;
    }
    try {
      await leaseRegistry.upsert(
        ProcessLease(
          id: effectiveLeaseId,
          pid: process.pid,
          kind: 'project-session',
          scope: LeaseScope.ephemeral,
          ownership: LeaseOwnership.owned,
          ownerCmd: 'oka:project-operations:${operation.id}',
          startedAt: DateTime.now().toUtc(),
          stopHint: LeaseStopHint(tool: 'kill', args: ['${process.pid}']),
          identity: {processLeasePidTokenKey: ?token},
        ),
      );
    } on Object catch (error) {
      await _stopProcessTree(process.pid, token);
      return _failure(
        'project_session_lease_failed',
        '$error; the spawned process was stopped',
      );
    }
    final ready = await _awaitReadiness(operation, process, target);
    if (!ready.ok) {
      await _stopProcessTree(process.pid, token);
      await leaseRegistry.delete(effectiveLeaseId);
      return _failure(
        ready.error!,
        ready.detail,
        exitCode: ready.exitCode,
        stderr: ready.stderr,
        pid: ready.pid,
      );
    }
    _url = target;
    _ownership = ProjectSessionOwnership.owned;
    _pid = process.pid;
    _identityToken = token;
    _attached = true;
    return ProjectBrowserSessionOutcome(
      ok: true,
      url: target,
      ownership: ProjectSessionOwnership.owned,
      pid: process.pid,
    );
  }

  Directory _resolveDirectory(ProjectDirectory reference) {
    switch (reference.kind) {
      case ProjectDirectoryKind.project:
        return workspace;
      case ProjectDirectoryKind.candidate:
        throw const FormatException(
          'project_session_candidate_directory_unavailable',
        );
      case ProjectDirectoryKind.external:
        final path = reference.path;
        if (path == null || !path.startsWith('/')) {
          throw const FormatException(
            'project_operation_absolute_path_required',
          );
        }
        return Directory(path);
    }
  }

  Future<ProjectBrowserSessionOutcome> _awaitReadiness(
    ProjectOperation operation,
    Process process,
    Uri target,
  ) async {
    final readiness =
        operation.readiness ??
        (operation.endpoint == null
            ? null
            : ProjectReadiness.tcp(
                host: operation.endpoint!.host,
                port: operation.endpoint!.port,
              ));
    if (readiness == null) {
      return ProjectBrowserSessionOutcome(
        ok: true,
        url: target,
        ownership: ProjectSessionOwnership.owned,
        pid: process.pid,
      );
    }
    final exited = Completer<int>();
    unawaited(
      process.exitCode.then(
        exited.complete,
        onError: (Object _) => exited.complete(-1),
      ),
    );
    final lines = <String>[];
    final stderrLines = <String>[];
    var wake = Completer<void>();
    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          lines.add(line);
          if (lines.length > 200) lines.removeAt(0);
          if (!wake.isCompleted) wake.complete();
        });
    final stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stderrLines.add(line);
          if (stderrLines.length > 200) stderrLines.removeAt(0);
        });
    final deadline = DateTime.now().add(readinessTimeout);
    try {
      while (true) {
        if (await _probe(readiness, lines)) {
          return ProjectBrowserSessionOutcome(
            ok: true,
            url: target,
            ownership: ProjectSessionOwnership.owned,
            pid: process.pid,
          );
        }
        if (exited.isCompleted) {
          return ProjectBrowserSessionOutcome(
            ok: false,
            url: target,
            ownership: ProjectSessionOwnership.owned,
            error: 'project_session_exited_before_ready',
            exitCode: await exited.future,
            stderr: stderrLines.join('\n'),
            pid: process.pid,
          );
        }
        if (!DateTime.now().isBefore(deadline)) {
          return ProjectBrowserSessionOutcome(
            ok: false,
            url: target,
            ownership: ProjectSessionOwnership.owned,
            error: 'project_session_readiness_timeout',
            detail:
                'the declared readiness was not satisfied within '
                '${readinessTimeout.inMilliseconds}ms',
            stderr: stderrLines.join('\n'),
            pid: process.pid,
          );
        }
        wake = Completer<void>();
        await Future.any<Object?>([
          Future<void>.delayed(const Duration(milliseconds: 100)),
          wake.future,
        ]);
      }
    } finally {
      await stdoutSub.cancel();
      await stderrSub.cancel();
    }
  }

  Future<bool> _probe(ProjectReadiness readiness, List<String> lines) async {
    switch (readiness.kind) {
      case ProjectReadinessKind.tcp:
        return _tcpReachable(readiness.host!, readiness.port!);
      case ProjectReadinessKind.filePresent:
        return File(readiness.path!).existsSync();
      case ProjectReadinessKind.logLine:
        final pattern = readiness.pattern!;
        return lines.any((line) => pattern.allMatches(line).isNotEmpty);
    }
  }

  Future<bool> _tcpReachable(String host, int port) async {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 300),
      );
      socket.destroy();
      return true;
    } on Object {
      return false;
    }
  }

  /// Stops the process this session spawned, and only that one.
  ///
  /// A missing spawn identity means the process cannot be signalled
  /// safely: the session reports it instead of guessing (report-never-guess).
  Future<void> _stopOwned() async {
    final pid = _pid;
    if (pid == null) {
      _attached = false;
      return;
    }
    await _stopProcessTree(pid, _identityToken);
    await leaseRegistry.delete(effectiveLeaseId);
    _pid = null;
    _identityToken = null;
    _attached = false;
    _ownership = null;
  }

  Future<void> _stopProcessTree(int pid, String? token) async {
    if (token == null) {
      // Without a spawn identity the process cannot be signalled safely.
      return;
    }
    await stopProcessTree(
      probe: treeProbe,
      liveness: liveness,
      rootPid: pid,
      rootIdentityToken: token,
      grace: stopGrace,
    );
  }

  ProjectBrowserSessionOutcome _failure(
    String error,
    String? detail, {
    int? exitCode,
    String stderr = '',
    int? pid,
  }) {
    final retained = _url;
    return ProjectBrowserSessionOutcome(
      ok: false,
      url: retained,
      ownership: _ownership,
      error: error,
      detail: detail,
      exitCode: exitCode,
      stderr: stderr,
      retainedLastKnownGood: retained != null,
      pid: pid,
    );
  }

  ProjectBrowserSessionOutcome _record(ProjectBrowserSessionOutcome outcome) {
    _lastOutcome = outcome;
    return outcome;
  }
}
