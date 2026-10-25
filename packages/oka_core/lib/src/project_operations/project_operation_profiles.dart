/// Shipped fixtures of the declared project operation contract.
///
/// These are *fixtures*, not a survey of every ecosystem: each one is a
/// declaration of the commands one project kind publishes. A product, a
/// project or a user may declare another profile with the same contract.
///
/// The Dart/Flutter fixture keeps the product's own vocabulary; the
/// React/npm fixture exists to prove the contract is not Dart-shaped. It
/// makes no product promise about any framework.
library;

import 'project_operation_profile.dart';

/// A Dart or Flutter project.
///
/// The `check` operation is the analyzer over the project root; the `serve`
/// operation is the Flutter web-server device on the declared port. Both
/// are the project's own commands — the profile never guesses a script name
/// the project does not publish.
const ProjectOperationProfile dartFlutterProfile = ProjectOperationProfile(
  id: 'dart_flutter',
  operations: <ProjectOperation>[
    ProjectOperation(
      id: 'check',
      kind: ProjectOperationKind.check,
      command: ProjectCommand(
        executable: 'dart',
        arguments: <String>['analyze'],
      ),
    ),
    ProjectOperation(
      id: 'build',
      kind: ProjectOperationKind.build,
      command: ProjectCommand(
        executable: 'flutter',
        arguments: <String>['build', 'web', '--release'],
      ),
    ),
    ProjectOperation(
      id: 'serve',
      kind: ProjectOperationKind.serve,
      command: ProjectCommand(
        executable: 'flutter',
        arguments: <String>['run', '-d', 'web-server', '--web-port', '8080'],
        timeout: Duration(minutes: 30),
      ),
      endpoint: ProjectEndpoint(host: '127.0.0.1', port: 8080),
      readiness: ProjectReadiness.tcp(host: '127.0.0.1', port: 8080),
    ),
  ],
);

/// A Node/npm project.
///
/// The `check` operation is the project's own build script — npm reports a
/// missing script as a failure rather than a silent success. The `serve`
/// operation is the project's own dev script with an explicit port; the
/// endpoint and the readiness are declared, never inferred from a log line.
const ProjectOperationProfile reactNpmProfile = ProjectOperationProfile(
  id: 'react_npm',
  operations: <ProjectOperation>[
    ProjectOperation(
      id: 'check',
      kind: ProjectOperationKind.check,
      command: ProjectCommand(
        executable: 'npm',
        arguments: <String>['run', 'build'],
      ),
    ),
    ProjectOperation(
      id: 'serve',
      kind: ProjectOperationKind.serve,
      command: ProjectCommand(
        executable: 'npm',
        arguments: <String>['run', 'dev', '--', '--port', '5173'],
        timeout: Duration(minutes: 30),
      ),
      endpoint: ProjectEndpoint(host: '127.0.0.1', port: 5173),
      readiness: ProjectReadiness.tcp(host: '127.0.0.1', port: 5173),
    ),
  ],
);

/// The shipped fixture profiles.
const List<ProjectOperationProfile> projectOperationProfiles =
    <ProjectOperationProfile>[dartFlutterProfile, reactNpmProfile];

/// The shipped profile whose id is [id], or null when no such profile ships.
ProjectOperationProfile? projectOperationProfileById(String id) {
  for (final profile in projectOperationProfiles) {
    if (profile.id == id) return profile;
  }
  return null;
}
