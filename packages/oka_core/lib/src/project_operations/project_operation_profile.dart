/// Declared project operations for ordinary coding projects.
///
/// A profile is *data*: the commands a project kind publishes, with an exact
/// executable and argument list, an explicit working-directory reference and
/// explicit environment overrides. Nothing here parses a shell string,
/// guesses a command from a file name, or asks a shell to interpret a
/// command line.
///
/// Dart, Flutter, React/npm and any other project kind are fixtures of the
/// same contract. The controller carries no per-language branch.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// What a declared operation does.
enum ProjectOperationKind {
  /// Verifies a working tree or a staged candidate.
  check,

  /// Produces build output from the working tree.
  build,

  /// Runs a long-lived process that backs a browser target.
  serve,
}

/// Where a declared command runs.
enum ProjectDirectoryKind {
  /// The staged candidate under verification.
  candidate,

  /// The owner project root.
  project,

  /// An explicit absolute path outside the project, such as a package root.
  external,
}

/// A declared working directory for a command.
final class ProjectDirectory {
  /// The staged candidate under verification.
  const ProjectDirectory.candidate()
    : kind = ProjectDirectoryKind.candidate,
      path = null;

  /// The owner project root.
  const ProjectDirectory.project()
    : kind = ProjectDirectoryKind.project,
      path = null;

  /// An explicit absolute path outside the project.
  const ProjectDirectory.external(String absolutePath)
    : kind = ProjectDirectoryKind.external,
      path = absolutePath;

  /// Which directory this reference names.
  final ProjectDirectoryKind kind;

  /// The absolute path of an [ProjectDirectoryKind.external] reference.
  final String? path;

  /// The evidence projection of this reference.
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    if (path != null) 'path': path,
  };
}

/// A declared command: exact argv, explicit working directory, explicit
/// environment.
///
/// The executable is resolved by the process spawn itself, the way every
/// program resolves a program; the arguments are handed over as they are
/// declared, so an argument that contains spaces stays one argument.
final class ProjectCommand {
  /// Declares a command.
  const ProjectCommand({
    required this.executable,
    this.arguments = const <String>[],
    this.workingDirectory = const ProjectDirectory.project(),
    this.environment = const <String, String>{},
    this.timeout = const Duration(minutes: 10),
  });

  /// The program to run, e.g. `npm` or `dart`.
  final String executable;

  /// The exact arguments, in order.
  final List<String> arguments;

  /// Where the command runs.
  final ProjectDirectory workingDirectory;

  /// Environment overrides applied on top of the inherited environment.
  final Map<String, String> environment;

  /// The deadline of a bounded run of this command.
  final Duration timeout;

  /// The exact argv of this command, executable first.
  List<String> get argv => <String>[executable, ...arguments];

  /// The evidence projection of this command.
  Map<String, Object?> toJson() => {
    'executable': executable,
    'arguments': List<String>.unmodifiable(arguments),
    'workingDirectory': workingDirectory.toJson(),
    'environment': Map<String, String>.unmodifiable(environment),
    'timeoutMs': timeout.inMilliseconds,
  };
}

/// How a declared readiness is probed.
enum ProjectReadinessKind {
  /// The declared endpoint accepts a TCP connection.
  tcp,

  /// The process printed a matching line.
  logLine,

  /// A file exists.
  filePresent,
}

/// A declared readiness probe for a serve operation.
final class ProjectReadiness {
  /// The declared endpoint accepts a TCP connection.
  const ProjectReadiness.tcp({required this.host, required this.port})
    : kind = ProjectReadinessKind.tcp,
      path = null,
      pattern = null;

  /// The process printed a line matching [pattern].
  const ProjectReadiness.logLine(this.pattern)
    : kind = ProjectReadinessKind.logLine,
      host = null,
      port = null,
      path = null;

  /// A file exists at [path].
  const ProjectReadiness.filePresent(this.path)
    : kind = ProjectReadinessKind.filePresent,
      host = null,
      port = null,
      pattern = null;

  /// How this probe is evaluated.
  final ProjectReadinessKind kind;

  /// The host of a [ProjectReadinessKind.tcp] probe.
  final String? host;

  /// The port of a [ProjectReadinessKind.tcp] probe.
  final int? port;

  /// The path of a [ProjectReadinessKind.filePresent] probe.
  final String? path;

  /// The pattern of a [ProjectReadinessKind.logLine] probe.
  final Pattern? pattern;

  /// The evidence projection of this probe.
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    if (host != null) 'host': host,
    if (port != null) 'port': port,
    if (path != null) 'path': path,
    if (pattern != null) 'pattern': pattern.toString(),
  };
}

/// A declared endpoint a serve operation exposes.
final class ProjectEndpoint {
  /// Declares an endpoint.
  const ProjectEndpoint({
    required this.host,
    required this.port,
    this.path = '/',
  });

  /// The host the endpoint is bound to.
  final String host;

  /// The port the endpoint is bound to.
  final int port;

  /// The path a browser window navigates to.
  final String path;

  /// The URL a browser window navigates to.
  Uri toUri() => Uri(scheme: 'http', host: host, port: port, path: path);

  /// The evidence projection of this endpoint.
  Map<String, Object?> toJson() => {'host': host, 'port': port, 'path': path};
}

/// One declared operation of a profile.
final class ProjectOperation {
  /// Declares an operation.
  const ProjectOperation({
    required this.id,
    required this.kind,
    required this.command,
    this.endpoint,
    this.readiness,
    this.timeout,
  });

  /// The stable id of this operation, e.g. `check`.
  final String id;

  /// What this operation does.
  final ProjectOperationKind kind;

  /// The declared command.
  final ProjectCommand command;

  /// The endpoint this operation exposes, when it serves one.
  final ProjectEndpoint? endpoint;

  /// The declared readiness of this operation.
  final ProjectReadiness? readiness;

  /// The deadline override of this operation.
  final Duration? timeout;

  /// The evidence projection of this operation.
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'command': command.toJson(),
    if (endpoint != null) 'endpoint': endpoint!.toJson(),
    if (readiness != null) 'readiness': readiness!.toJson(),
  };
}

/// The commands one project kind publishes.
///
/// A profile is opt-in data: the product ships fixtures, and a project (or
/// a user) may declare its own. The profile never invents a command that it
/// did not declare.
final class ProjectOperationProfile {
  /// Declares a profile.
  const ProjectOperationProfile({
    required this.id,
    required this.operations,
    this.externalPackageRoots = const <String, String>{},
  });

  /// The stable id of this profile, e.g. `dart_flutter`.
  final String id;

  /// The declared operations, in declaration order.
  final List<ProjectOperation> operations;

  /// External package roots referenced (linked) into a staged candidate,
  /// keyed by the name they take inside the candidate.
  ///
  /// An ordinary dependency tree is far too large to copy per candidate, so
  /// the root is referenced, never duplicated.
  final Map<String, String> externalPackageRoots;

  /// The declared operation of [kind], or null when the profile does not
  /// declare one.
  ProjectOperation? operation(ProjectOperationKind kind) {
    for (final operation in operations) {
      if (operation.kind == kind) return operation;
    }
    return null;
  }

  /// Whether this profile declares an operation of [kind].
  bool supports(ProjectOperationKind kind) => operation(kind) != null;

  /// The evidence projection of this profile.
  Map<String, Object?> toJson() => {
    'id': id,
    'operations': [for (final operation in operations) operation.toJson()],
    if (externalPackageRoots.isNotEmpty)
      'externalPackageRoots': Map<String, String>.unmodifiable(
        externalPackageRoots,
      ),
  };

  /// A stable digest of this profile, for evidence and cache keys.
  String digest() =>
      sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();
}
