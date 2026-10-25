import 'package:oka_core/project_operations.dart';
import 'package:test/test.dart';

void main() {
  test('a profile declares exact argv, never a command string', () {
    const profile = ProjectOperationProfile(
      id: 'fixture',
      operations: <ProjectOperation>[
        ProjectOperation(
          id: 'check',
          kind: ProjectOperationKind.check,
          command: ProjectCommand(
            executable: 'npm',
            arguments: <String>['run', 'build'],
          ),
        ),
      ],
    );
    final operation = profile.operation(ProjectOperationKind.check);
    expect(operation, isNotNull);
    expect(operation!.command.argv, <String>['npm', 'run', 'build']);
    expect(operation.command.executable, 'npm');
    expect(profile.supports(ProjectOperationKind.check), isTrue);
    expect(profile.supports(ProjectOperationKind.build), isFalse);
    expect(profile.operation(ProjectOperationKind.build), isNull);
  });

  test('an argument with spaces stays one argument', () {
    const command = ProjectCommand(
      executable: 'tool',
      arguments: <String>['--label', 'two words', 'tail'],
    );
    expect(command.argv, <String>['tool', '--label', 'two words', 'tail']);
    expect(command.argv[2], 'two words');
  });

  test('the shipped fixtures declare their own commands', () {
    expect(dartFlutterProfile.id, 'dart_flutter');
    expect(
      dartFlutterProfile.operation(ProjectOperationKind.check)!.command.argv,
      <String>['dart', 'analyze'],
    );
    expect(
      dartFlutterProfile.operation(ProjectOperationKind.build)!.command.argv,
      <String>['flutter', 'build', 'web', '--release'],
    );
    expect(
      dartFlutterProfile.operation(ProjectOperationKind.serve)!.endpoint!.port,
      8080,
    );
    expect(reactNpmProfile.id, 'react_npm');
    expect(
      reactNpmProfile.operation(ProjectOperationKind.check)!.command.argv,
      <String>['npm', 'run', 'build'],
    );
    expect(
      reactNpmProfile.operation(ProjectOperationKind.serve)!.command.argv,
      <String>['npm', 'run', 'dev', '--', '--port', '5173'],
    );
    expect(
      reactNpmProfile.operation(ProjectOperationKind.serve)!.endpoint!.port,
      5173,
    );
    expect(projectOperationProfileById('react_npm'), same(reactNpmProfile));
    expect(projectOperationProfileById('absent'), isNull);
  });

  test('a directory reference is explicit about where it points', () {
    const candidate = ProjectDirectory.candidate();
    const project = ProjectDirectory.project();
    const external = ProjectDirectory.external('/tmp/package root');
    expect(candidate.kind, ProjectDirectoryKind.candidate);
    expect(candidate.path, isNull);
    expect(project.kind, ProjectDirectoryKind.project);
    expect(external.kind, ProjectDirectoryKind.external);
    expect(external.path, '/tmp/package root');
    expect(external.toJson()['path'], '/tmp/package root');
  });

  test('a profile digest is stable over its declaration', () {
    expect(reactNpmProfile.digest(), reactNpmProfile.digest());
    expect(reactNpmProfile.digest().isNotEmpty, isTrue);
    expect(reactNpmProfile.digest() == dartFlutterProfile.digest(), isFalse);
  });
}
