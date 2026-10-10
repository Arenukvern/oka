import 'dart:convert';
import 'dart:io';

import 'package:oka/src/cli/supervisor_command.dart';
import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `oka supervisor` wiring (ADR-0040/0041): status is a records-only
/// read over the registry root it is given; apply validates the plan
/// before converge and exits nonzero on failure. Every test passes
/// --project/--registry-root into a temp dir so the real ~/.oka and
/// ~/.oka_cache are never touched.
void main() {
  late Directory temp;
  late String project;
  late String registryRoot;
  final output = <String>[];
  final errors = <String>[];
  final exitCodes = <int>[];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka_supervisor_cli_');
    project = p.join(temp.path, 'project');
    Directory(project).createSync(recursive: true);
    registryRoot = p.join(temp.path, 'supervisor');
    output.clear();
    errors.clear();
    exitCodes.clear();
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  SupervisorCommand command() => SupervisorCommand(
    output: output.add,
    errorOutput: errors.add,
    setExitCode: exitCodes.add,
  );

  File writePlan(Map<String, Object?> document) =>
      File(p.join(temp.path, 'plan.json'))
        ..writeAsStringSync(jsonEncode(document));

  Map<String, Object?> trueJobPlan() => {
    'version': 1,
    'specs': [
      {
        'id': 'true-job',
        'provider': 'process',
        'shape': 'job',
        'env': {'command': '/usr/bin/true'},
      },
    ],
  };

  test(
    'status with no records prints the no-records line and exits 0',
    () async {
      await command().run([
        'status',
        '--project',
        project,
        '--registry-root',
        registryRoot,
      ]);

      final scope = MachineRegistry(root: registryRoot).scopeFor(project);
      expect(
        output.join('\n'),
        contains('no supervisor records for this project (scope $scope)'),
      );
      expect(exitCodes, isEmpty);
      expect(errors, isEmpty);
    },
  );

  test(
    'status --json emits parseable JSON with statuses + corruptRecords',
    () async {
      await command().run([
        'status',
        '--project',
        project,
        '--registry-root',
        registryRoot,
        '--json',
      ]);

      final document = jsonDecode(output.join('\n')) as Map<String, Object?>;
      expect(document.keys, containsAll(['statuses', 'corruptRecords']));
      expect(document['statuses'], isEmpty);
      expect(document['corruptRecords'], isEmpty);
    },
  );

  test('apply with a missing plan file exits 1', () async {
    await command().run([
      'apply',
      p.join(temp.path, 'absent.json'),
      '--project',
      project,
      '--registry-root',
      registryRoot,
    ]);

    expect(exitCodes, [1]);
    expect(errors.join('\n'), contains('Cannot read supervisor plan'));
  });

  test(
    'apply with an invalid plan document exits 1 naming the problem',
    () async {
      final plan = writePlan({'version': 99, 'specs': []});

      await command().run([
        'apply',
        plan.path,
        '--project',
        project,
        '--registry-root',
        registryRoot,
      ]);

      expect(exitCodes, [1]);
      expect(errors.join('\n'), contains('invalid supervisor plan'));
    },
  );

  test('apply --dry-run prints a plan and starts nothing', () async {
    final plan = writePlan(trueJobPlan());

    await command().run([
      'apply',
      plan.path,
      '--dry-run',
      '--project',
      project,
      '--registry-root',
      registryRoot,
    ]);

    final text = output.join('\n');
    expect(text, contains('plan:'));
    expect(text, contains('start true-job'));
    expect(text, contains('Dry run'));
    expect(exitCodes, isEmpty);
    // Nothing was applied: no registry scope was ever created.
    expect(Directory(p.join(registryRoot, 'records')).existsSync(), isFalse);
  });

  test('apply with an unknown provider exits 1 naming the provider', () async {
    final plan = writePlan({
      'version': 1,
      'specs': [
        {'id': 'web', 'provider': 'docker'},
      ],
    });

    await command().run([
      'apply',
      plan.path,
      '--project',
      project,
      '--registry-root',
      registryRoot,
    ]);

    expect(exitCodes, [1]);
    expect(
      errors.join('\n'),
      contains('unknown provider "docker"; this CLI provides: process'),
    );
  });

  test(
    'apply runs a job to terminal success and status shows the record',
    () async {
      final plan = writePlan(trueJobPlan());

      await command().run([
        'apply',
        plan.path,
        '--project',
        project,
        '--registry-root',
        registryRoot,
      ]);

      expect(exitCodes, isEmpty);
      expect(output.join('\n'), contains('start true-job'));
      final registry = MachineRegistry(root: registryRoot);
      final record = registry.read(registry.scopeFor(project), 'true-job');
      expect(record, isNotNull);
      expect(record!.lastRun, 'succeeded');

      await command().run([
        'status',
        '--project',
        project,
        '--registry-root',
        registryRoot,
      ]);
      expect(output.join('\n'), contains('true-job'));
    },
  );

  test('apply --evidence appends lifecycle facts as JSONL', () async {
    final plan = writePlan(trueJobPlan());
    final factsPath = p.join(temp.path, 'facts.jsonl');

    await command().run([
      'apply',
      plan.path,
      '--project',
      project,
      '--registry-root',
      registryRoot,
      '--evidence',
      factsPath,
    ]);

    expect(exitCodes, isEmpty);
    final lines = File(
      factsPath,
    ).readAsLinesSync().where((final line) => line.isNotEmpty).toList();
    expect(lines, isNotEmpty);
    expect(jsonDecode(lines.first), isA<Map<String, Object?>>());
  });

  test('check passes when records match the committed plan', () async {
    final plan = writePlan(trueJobPlan());
    await command().run([
      'apply',
      plan.path,
      '--project',
      project,
      '--registry-root',
      registryRoot,
    ]);
    output.clear();

    await command().run([
      'check',
      plan.path,
      '--project',
      project,
      '--registry-root',
      registryRoot,
    ]);

    expect(exitCodes, isEmpty);
    expect(output.join('\n'), contains('check ok'));
  });

  test('check fails on revision drift between plan and record', () async {
    final applied = writePlan(trueJobPlan());
    await command().run([
      'apply',
      applied.path,
      '--project',
      project,
      '--registry-root',
      registryRoot,
    ]);
    output.clear();

    // Same id, different declaration: a different revision hash.
    final drifted = writePlan({
      'version': 1,
      'specs': [
        {
          'id': 'true-job',
          'provider': 'process',
          'shape': 'job',
          'env': {'command': '/usr/bin/false'},
        },
      ],
    });
    await command().run([
      'check',
      drifted.path,
      '--project',
      project,
      '--registry-root',
      registryRoot,
    ]);

    expect(exitCodes, [1]);
    final text = output.join('\n');
    expect(text, contains('check failed'));
    expect(text, contains('record drifted from plan'));
  });

  test('check fails when a declared service has no record', () async {
    final plan = writePlan({
      'version': 1,
      'specs': [
        {
          'id': 'api',
          'provider': 'process',
          'shape': 'service',
          'env': {'command': '/bin/sleep', 'args': '1'},
        },
      ],
    });

    await command().run([
      'check',
      plan.path,
      '--project',
      project,
      '--registry-root',
      registryRoot,
    ]);

    expect(exitCodes, [1]);
    expect(output.join('\n'), contains('has no record'));
  });

  test('check --json carries ok and named problems', () async {
    final plan = writePlan({
      'version': 1,
      'specs': [
        {
          'id': 'api',
          'provider': 'process',
          'shape': 'service',
          'env': {'command': '/bin/sleep', 'args': '1'},
        },
      ],
    });

    await command().run([
      'check',
      plan.path,
      '--project',
      project,
      '--registry-root',
      registryRoot,
      '--json',
    ]);

    final document = jsonDecode(output.join('\n')) as Map<String, Object?>;
    expect(document['ok'], isFalse);
    final problems = (document['problems']! as List<Object?>).cast<String>();
    expect(problems, hasLength(1));
    expect(problems.single, contains('api'));
  });

  test('check fails naming a corrupt record file', () async {
    final plan = writePlan(trueJobPlan());
    final scope = MachineRegistry(root: registryRoot).scopeFor(project);
    final scopeDir = Directory(p.join(registryRoot, 'records', scope))
      ..createSync(recursive: true);
    File(p.join(scopeDir.path, 'broken.json')).writeAsStringSync('{not json');

    await command().run([
      'check',
      plan.path,
      '--project',
      project,
      '--registry-root',
      registryRoot,
    ]);

    expect(exitCodes, [1]);
    expect(output.join('\n'), contains('corrupt record:'));
  });
}
