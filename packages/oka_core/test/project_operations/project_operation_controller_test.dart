import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_core/project_operations.dart';
import 'package:test/test.dart';

String? _findExecutable(List<String> candidates) {
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

void main() {
  test('external references cannot escape the staged candidate', () async {
    final root = await Directory.systemTemp.createTemp('project_reference_');
    addTearDown(() => root.delete(recursive: true));
    final candidate = Directory('${root.path}/candidate')..createSync();
    final external = Directory('${root.path}/external')..createSync();
    final controller = ProjectOperationController(
      workspace: root,
      profile: ProjectOperationProfile(
        id: 'invalid-reference',
        externalPackageRoots: {'../escape': external.path},
        operations: const [
          ProjectOperation(
            id: 'check',
            kind: ProjectOperationKind.check,
            command: ProjectCommand(
              executable: 'must-not-start',
              workingDirectory: ProjectDirectory.candidate(),
            ),
          ),
        ],
      ),
      runner:
          (
            executable,
            arguments, {
            required timeout,
            workingDirectory,
            environment,
            cancellation,
          }) async =>
              throw StateError('invalid references must refuse before spawn'),
    );
    final result = await controller.run(
      ProjectOperationKind.check,
      candidate: candidate,
    );
    expect(result.ok, isFalse);
    expect(result.error, 'project_operation_dependency_reference_refused');
    expect(Link('${root.path}/escape').existsSync(), isFalse);
  });
  final printfPath = _findExecutable(const ['/usr/bin/printf', '/bin/printf']);
  final catPath = _findExecutable(const ['/bin/cat', '/usr/bin/cat']);
  final pwdPath = _findExecutable(const ['/bin/pwd', '/usr/bin/pwd']);
  final sleepPath = _findExecutable(const ['/bin/sleep', '/usr/bin/sleep']);
  final printenvPath = _findExecutable(const [
    '/usr/bin/printenv',
    '/bin/printenv',
  ]);
  final posix = Platform.isWindows ? 'POSIX fixtures only' : null;

  ProjectOperationProfile profileOf(ProjectCommand command) =>
      ProjectOperationProfile(
        id: 'fixture',
        operations: <ProjectOperation>[
          ProjectOperation(
            id: 'check',
            kind: ProjectOperationKind.check,
            command: command,
          ),
        ],
      );

  test('a declared check runs in the project and reports its exit', () async {
    final tool = printfPath!;
    final root = await Directory.systemTemp.createTemp('project_ops_');
    addTearDown(() => root.delete(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final controller = ProjectOperationController(
      profile: profileOf(
        ProjectCommand(executable: tool, arguments: <String>['%s\n', 'ok']),
      ),
      workspace: project,
    );
    final outcome = await controller.run(ProjectOperationKind.check);
    expect(outcome.ok, isTrue, reason: '${outcome.toJson()}');
    expect(outcome.exitCode, 0);
    expect(outcome.stdout, 'ok\n');
    expect(outcome.error, isNull);
    expect(outcome.argv, <String>[tool, '%s\n', 'ok']);
    expect(outcome.workingDirectory, project.path);
    expect(outcome.physicallySettled, isTrue);
  }, skip: printfPath == null ? 'no printf available' : posix);

  test(
    'a failing command reports its exit code and its error output',
    () async {
      final tool = catPath!;
      final root = await Directory.systemTemp.createTemp('project_ops_');
      addTearDown(() => root.delete(recursive: true));
      final project = Directory('${root.path}/project')..createSync();
      final controller = ProjectOperationController(
        profile: profileOf(
          ProjectCommand(executable: tool, arguments: <String>['missing.txt']),
        ),
        workspace: project,
      );
      final outcome = await controller.run(ProjectOperationKind.check);
      expect(outcome.ok, isFalse);
      expect(outcome.error, 'project_operation_failed');
      expect(outcome.exitCode, 1);
      expect(outcome.stderr, contains('missing.txt'));
      expect(outcome.physicallySettled, isTrue);
    },
    skip: catPath == null ? 'no cat available' : posix,
  );

  test('a command that cannot start is a named failure, not a crash', () async {
    final root = await Directory.systemTemp.createTemp('project_ops_');
    addTearDown(() => root.delete(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final controller = ProjectOperationController(
      profile: profileOf(
        const ProjectCommand(executable: 'lastanswer-no-such-binary-4f21'),
      ),
      workspace: project,
    );
    final outcome = await controller.run(ProjectOperationKind.check);
    expect(outcome.ok, isFalse);
    expect(outcome.error, 'project_operation_spawn_failed');
    expect(outcome.exitCode, isNull);
    expect(outcome.physicallySettled, isTrue);
  });

  test('an argument with spaces reaches the command as one argument', () async {
    final tool = printfPath!;
    final root = await Directory.systemTemp.createTemp('project_ops_');
    addTearDown(() => root.delete(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final spaced = ProjectOperationController(
      profile: profileOf(
        ProjectCommand(
          executable: tool,
          arguments: <String>['%s\n', 'two words'],
        ),
      ),
      workspace: project,
    );
    final outcome = await spaced.run(ProjectOperationKind.check);
    expect(outcome.ok, isTrue, reason: '${outcome.toJson()}');
    expect(outcome.stdout, 'two words\n');
    final split = ProjectOperationController(
      profile: profileOf(
        ProjectCommand(
          executable: tool,
          arguments: <String>['%s\n', 'two', 'words'],
        ),
      ),
      workspace: project,
    );
    final control = await split.run(ProjectOperationKind.check);
    expect(control.stdout, 'two\nwords\n');
  }, skip: printfPath == null ? 'no printf available' : posix);

  test(
    'the working directory is the declared one, project or external',
    () async {
      final tool = pwdPath!;
      final root = await Directory.systemTemp.createTemp('project_ops_');
      addTearDown(() => root.delete(recursive: true));
      final project = Directory('${root.path}/project')..createSync();
      final external = Directory('${root.path}/package root')
        ..createSync(recursive: true);
      final inside = ProjectOperationController(
        profile: profileOf(
          // The default working directory is the owner project root.
          ProjectCommand(executable: tool),
        ),
        workspace: project,
      );
      final projectRun = await inside.run(ProjectOperationKind.check);
      expect(projectRun.stdout.trim(), project.resolveSymbolicLinksSync());
      final outside = ProjectOperationController(
        profile: profileOf(
          ProjectCommand(
            executable: tool,
            workingDirectory: ProjectDirectory.external(external.path),
          ),
        ),
        workspace: project,
      );
      final externalRun = await outside.run(ProjectOperationKind.check);
      expect(externalRun.stdout.trim(), external.resolveSymbolicLinksSync());
    },
    skip: pwdPath == null ? 'no pwd available' : posix,
  );

  test('the environment carries exactly the declared overrides', () async {
    final tool = printenvPath!;
    final root = await Directory.systemTemp.createTemp('project_ops_');
    addTearDown(() => root.delete(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final controller = ProjectOperationController(
      profile: profileOf(
        ProjectCommand(
          executable: tool,
          arguments: <String>['LAST_ANSWER_TEST_MARKER'],
        ),
      ),
      workspace: project,
      environment: const <String, String>{
        'LAST_ANSWER_TEST_MARKER': 'declared',
      },
    );
    final declared = await controller.run(ProjectOperationKind.check);
    expect(declared.ok, isTrue, reason: '${declared.toJson()}');
    expect(declared.stdout.trim(), 'declared');
    final undeclared = ProjectOperationController(
      profile: profileOf(
        ProjectCommand(
          executable: tool,
          arguments: <String>['LAST_ANSWER_TEST_MARKER'],
        ),
      ),
      workspace: project,
    );
    final missing = await undeclared.run(ProjectOperationKind.check);
    expect(missing.ok, isFalse);
    expect(missing.exitCode, 1);
  }, skip: printenvPath == null ? 'no printenv available' : posix);

  test('an external package root is referenced, never copied', () async {
    final tool = catPath!;
    final root = await Directory.systemTemp.createTemp('project_ops_');
    addTearDown(() => root.delete(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final candidate = Directory('${root.path}/candidate')..createSync();
    final external = Directory('${root.path}/external/node_modules')
      ..createSync(recursive: true);
    File('${external.path}/marker.txt').writeAsStringSync('external-marker');
    final controller = ProjectOperationController(
      profile: ProjectOperationProfile(
        id: 'fixture',
        operations: <ProjectOperation>[
          ProjectOperation(
            id: 'check',
            kind: ProjectOperationKind.check,
            command: ProjectCommand(
              executable: tool,
              arguments: <String>['node_modules/marker.txt'],
              workingDirectory: const ProjectDirectory.candidate(),
            ),
          ),
        ],
        externalPackageRoots: <String, String>{'node_modules': external.path},
      ),
      workspace: project,
    );
    final outcome = await controller.run(
      ProjectOperationKind.check,
      candidate: candidate,
    );
    expect(outcome.ok, isTrue, reason: '${outcome.toJson()}');
    expect(outcome.stdout.trim(), 'external-marker');
    expect(Directory('${candidate.path}/node_modules').existsSync(), isTrue);
    expect(File('${candidate.path}/node_modules').existsSync(), isFalse);
  }, skip: catPath == null ? 'no cat available' : posix);

  test('a deadline stops the command instead of abandoning it', () async {
    final tool = sleepPath!;
    final root = await Directory.systemTemp.createTemp('project_ops_');
    addTearDown(() => root.delete(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final controller = ProjectOperationController(
      profile: profileOf(
        ProjectCommand(
          executable: tool,
          arguments: <String>['30'],
          timeout: const Duration(milliseconds: 300),
        ),
      ),
      workspace: project,
    );
    final outcome = await controller.run(ProjectOperationKind.check);
    expect(outcome.ok, isFalse);
    expect(outcome.error, 'project_operation_deadline_exceeded');
    expect(
      outcome.physicallySettled || outcome.survivors.isNotEmpty,
      isTrue,
      reason: '${outcome.toJson()}',
    );
    final pid = outcome.pid;
    if (pid != null && outcome.physicallySettled) {
      expect(await const HostProcessLiveness().isAlive(pid), isFalse);
    }
  }, skip: sleepPath == null ? 'no sleep available' : posix);

  test('a candidate-scoped command without a candidate is refused', () async {
    final tool = printfPath!;
    final root = await Directory.systemTemp.createTemp('project_ops_');
    addTearDown(() => root.delete(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final controller = ProjectOperationController(
      profile: profileOf(
        ProjectCommand(
          executable: tool,
          workingDirectory: const ProjectDirectory.candidate(),
        ),
      ),
      workspace: project,
    );
    final outcome = await controller.run(ProjectOperationKind.check);
    expect(outcome.ok, isFalse);
    expect(outcome.error, 'project_operation_directory_unavailable');
    expect(outcome.detail, 'project_operation_candidate_required');
  }, skip: printfPath == null ? 'no printf available' : posix);

  test('an operation the profile does not declare is unavailable', () async {
    final root = await Directory.systemTemp.createTemp('project_ops_');
    addTearDown(() => root.delete(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final controller = ProjectOperationController(
      profile: profileOf(const ProjectCommand(executable: 'true')),
      workspace: project,
    );
    final outcome = await controller.run(ProjectOperationKind.build);
    expect(outcome.ok, isFalse);
    expect(outcome.error, 'project_operation_unavailable');
    expect(outcome.detail, contains('fixture'));
  });
}
