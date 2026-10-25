/// Runs the declared operations of a [ProjectOperationProfile].
///
/// The controller owns no storage, no process manager and no shell runner:
/// a bounded run and a lease registry are oka's, reused here. What the
/// controller adds is the *declared* contract — exact argv, an explicit
/// working directory, explicit environment — and an honest report of what
/// the command did.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../oka_core.dart';
import 'project_operation_profile.dart';

/// Runs a bounded process for a declared project command.
///
/// The default implementation is oka's bounded run: the deadline stops the
/// discovered process tree instead of abandoning the child, and the outcome
/// carries the exit code, the captured output and the teardown receipt.
///
/// A [cancellation] is the same stop, requested before the deadline: the run
/// owns exactly one identity-gated tree stop, and the outcome reports the
/// cancellation cause with the teardown verification the deadline reports.
typedef ProjectProcessRunner = Future<BoundedRunResult> Function(
  String executable,
  List<String> arguments, {
  required Duration timeout,
  String? workingDirectory,
  Map<String, String>? environment,
  ProcessRunCancellation? cancellation,
});

Future<BoundedRunResult> _okaBoundedRun(
  String executable,
  List<String> arguments, {
  required Duration timeout,
  String? workingDirectory,
  Map<String, String>? environment,
  ProcessRunCancellation? cancellation,
}) => runBoundedProcess(
  executable,
  arguments,
  timeout: timeout,
  workingDirectory: workingDirectory,
  environment: environment,
  cancellation: cancellation,
);

/// The captured result of one declared operation run.
final class ProjectOperationOutcome {
  /// Describes one run.
  const ProjectOperationOutcome({
    required this.ok,
    required this.kind,
    required this.operationId,
    required this.argv,
    required this.workingDirectory,
    required this.duration,
    this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.error,
    this.detail,
    this.physicallySettled = true,
    this.truncatedOutput = false,
    this.survivors = const <int>[],
    this.pid,
    this.rootIdentityToken,
  });

  /// Whether the command reported success.
  final bool ok;

  /// What the operation does.
  final ProjectOperationKind kind;

  /// The id of the declared operation.
  final String operationId;

  /// The exact argv that ran.
  final List<String> argv;

  /// The directory the command ran in.
  final String workingDirectory;

  /// How long the command took.
  final Duration duration;

  /// The exit code, when the command exited on its own.
  final int? exitCode;

  /// The captured standard output.
  final String stdout;

  /// The captured standard error.
  final String stderr;

  /// The named failure, when the run failed.
  final String? error;

  /// The detail of the named failure.
  final String? detail;

  /// Whether the command's work physically stopped.
  ///
  /// A deadline that stopped the process tree is settled only when the
  /// teardown verified; an unverified stop is reported as unsettled, never
  /// as a clean failure.
  final bool physicallySettled;

  /// Whether the captured output was truncated.
  final bool truncatedOutput;

  /// The pids that survived a deadline stop.
  final List<int> survivors;

  /// The pid of the spawned command, when it was spawned.
  final int? pid;

  /// The bounded run's process identity, retained for owner-gated recovery.
  final String? rootIdentityToken;

  /// The evidence projection of this outcome.
  Map<String, Object?> toJson() => {
    'ok': ok,
    'kind': kind.name,
    'operation': operationId,
    'argv': List<String>.unmodifiable(argv),
    'workingDirectory': workingDirectory,
    'exitCode': exitCode,
    'durationMs': duration.inMilliseconds,
    'stdout': stdout,
    'stderr': stderr,
    if (error != null) 'error': error,
    if (detail != null) 'detail': detail,
    'physicallySettled': physicallySettled,
    'truncatedOutput': truncatedOutput,
    if (survivors.isNotEmpty) 'survivors': List<int>.unmodifiable(survivors),
    if (pid != null) 'pid': pid,
    if (rootIdentityToken != null) 'rootIdentityToken': rootIdentityToken,
  };
}

/// Runs the declared operations of one profile against one project.
final class ProjectOperationController {
  /// Creates a controller.
  ProjectOperationController({
    required this.profile,
    required this.workspace,
    this.environment = const <String, String>{},
    ProjectProcessRunner? runner,
  }) : _runner = runner ?? _okaBoundedRun;

  /// The declared commands.
  final ProjectOperationProfile profile;

  /// The owner project root.
  final Directory workspace;

  /// Environment overrides applied to every run on top of the inherited
  /// environment and the command's own overrides.
  final Map<String, String> environment;

  final ProjectProcessRunner _runner;

  ProcessRunCancellation? _activeCancellation;

  /// The cancellation of the run in flight, when one is running.
  ///
  /// The controller owns the cancellation: the caller asks the controller to
  /// stop, and the controller hands the request to the run.
  ProcessRunCancellation? get activeCancellation => _activeCancellation;

  /// Requests the cancellation of the run in flight.
  ///
  /// Returns false when no run is in flight. The request is idempotent: the
  /// run performs exactly one identity-gated tree stop, the same stop the
  /// deadline performs, and reports the teardown verification in its result.
  bool cancelActiveRun() {
    final cancellation = _activeCancellation;
    if (cancellation == null) return false;
    cancellation.request();
    return true;
  }

  /// Runs the declared operation of [kind].
  ///
  /// [candidate] is the staged tree under verification; it is the target of
  /// a [ProjectDirectoryKind.candidate] working directory. The command is
  /// never assembled into a command string: the executable and its arguments
  /// reach the process spawn exactly as declared, so an argument containing
  /// spaces stays one argument.
  Future<ProjectOperationOutcome> run(
    ProjectOperationKind kind, {
    Directory? candidate,
    Map<String, String> extraEnvironment = const <String, String>{},
  }) async {
    final operation = profile.operation(kind);
    if (operation == null) {
      return ProjectOperationOutcome(
        ok: false,
        kind: kind,
        operationId: kind.name,
        argv: const <String>[],
        workingDirectory: workspace.path,
        duration: Duration.zero,
        error: 'project_operation_unavailable',
        detail:
            'the profile "${profile.id}" declares no ${kind.name} operation',
      );
    }
    final Directory directory;
    try {
      directory = resolveDirectory(
        operation.command.workingDirectory,
        candidate,
      );
    } on FormatException catch (error) {
      return ProjectOperationOutcome(
        ok: false,
        kind: kind,
        operationId: operation.id,
        argv: operation.command.argv,
        workingDirectory: workspace.path,
        duration: Duration.zero,
        error: 'project_operation_directory_unavailable',
        detail: error.message,
      );
    }
    try {
      _referenceExternalPackageRoots(directory, candidate);
    } on FileSystemException catch (error) {
      return ProjectOperationOutcome(
        ok: false,
        kind: kind,
        operationId: operation.id,
        argv: operation.command.argv,
        workingDirectory: directory.path,
        duration: Duration.zero,
        error: 'project_operation_dependency_reference_refused',
        detail: error.message,
      );
    }
    final overrides = <String, String>{
      ...environment,
      ...operation.command.environment,
      ...extraEnvironment,
    };
    final cancellation = _activeCancellation = ProcessRunCancellation();
    late final BoundedRunResult result;
    try {
      result = await _runner(
        operation.command.executable,
        operation.command.arguments,
        timeout: operation.timeout ?? operation.command.timeout,
        workingDirectory: directory.path,
        environment: overrides.isEmpty ? null : overrides,
        cancellation: cancellation,
      );
    } finally {
      _activeCancellation = null;
    }
    return _outcomeOf(operation, result, directory);
  }

  /// Resolves a declared working directory against this run's scope.
  Directory resolveDirectory(ProjectDirectory reference, Directory? candidate) {
    switch (reference.kind) {
      case ProjectDirectoryKind.candidate:
        final staged = candidate;
        if (staged == null) {
          throw const FormatException('project_operation_candidate_required');
        }
        return staged;
      case ProjectDirectoryKind.project:
        return workspace;
      case ProjectDirectoryKind.external:
        final path = reference.path;
        if (path == null || !p.isAbsolute(path)) {
          throw const FormatException(
            'project_operation_absolute_path_required',
          );
        }
        return Directory(path);
    }
  }

  /// References the profile's external package roots inside the staged
  /// candidate.
  ///
  /// The roots are linked, never copied: an ordinary dependency tree is far
  /// too large to duplicate per candidate. A missing root is left missing —
  /// the command then fails for a reason it can report itself.
  void _referenceExternalPackageRoots(
    Directory directory,
    Directory? candidate,
  ) {
    if (candidate == null) return;
    if (directory.path != candidate.path) return;
    final root = candidate.resolveSymbolicLinksSync();
    // Validate the whole declaration before creating any references.
    for (final name in profile.externalPackageRoots.keys) {
      final destination = p.normalize(p.join(root, name));
      if (p.isAbsolute(name) || !p.isWithin(root, destination)) {
        throw FileSystemException(
          'dependency reference escapes candidate',
          name,
        );
      }
      var parent = p.dirname(destination);
      while (!Directory(parent).existsSync() && p.isWithin(root, parent)) {
        parent = p.dirname(parent);
      }
      final realParent = Directory(parent).resolveSymbolicLinksSync();
      if (realParent != root && !p.isWithin(root, realParent)) {
        throw FileSystemException('dependency parent escapes candidate', name);
      }
    }
    for (final entry in profile.externalPackageRoots.entries) {
      final target = Directory(entry.value);
      if (!target.existsSync()) continue;
      final link = Link('${candidate.path}/${entry.key}');
      if (link.existsSync()) continue;
      final parent = File(link.path).parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      link.createSync(target.path);
    }
  }

  ProjectOperationOutcome _outcomeOf(
    ProjectOperation operation,
    BoundedRunResult result,
    Directory directory,
  ) {
    final error = switch (result.cause) {
      BoundedRunCause.exited =>
        result.exitCode == 0 ? null : 'project_operation_failed',
      BoundedRunCause.signaled => 'project_operation_signaled',
      BoundedRunCause.killedOnDeadline => 'project_operation_deadline_exceeded',
      BoundedRunCause.cancelled => 'project_operation_cancelled',
      BoundedRunCause.spawnFailed => 'project_operation_spawn_failed',
    };
    // A stop that could not be verified leaves the work unsettled: the
    // process may still be alive and its recovery receipt must be retained.
    final settled = switch (result.cause) {
      BoundedRunCause.killedOnDeadline => result.teardownVerified == true,
      BoundedRunCause.cancelled => result.teardownVerified != false,
      _ => true,
    };
    return ProjectOperationOutcome(
      ok: result.ok,
      kind: operation.kind,
      operationId: operation.id,
      argv: operation.command.argv,
      workingDirectory: directory.path,
      duration: result.duration,
      exitCode: result.cause == BoundedRunCause.spawnFailed
          ? null
          : result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
      error: error,
      detail: result.errorMessage,
      physicallySettled: settled,
      truncatedOutput: result.truncatedOutput,
      survivors: result.survivors,
      pid: result.rootPid,
      rootIdentityToken: result.rootIdentityToken,
    );
  }
}
