// ADR-0015 — CLI verb/target split: `Target` contract + `oka run` dispatcher.
//
// Covers:
// * target name validation (lowercase identifiers, reserved verb shadowing,
//   duplicates) — the verb/target collision law;
// * target → pipeline compilation validated via `Pipeline.validate` before
//   any tool runs;
// * `oka run <target>` dispatch through the project entrypoint
//   (`tool/oka_pipeline.dart`, same discovery `oka build` uses);
// * unknown-verb dispatch naming the available targets;
// * the entrypoint-less project case (points at `oka init`).
//
// The dispatch tests run the real CLI (`dart run packages/oka/bin/oka.dart …`) against a
// sandbox project under `.oka_cache/` (gitignored) whose entrypoint is the
// fixture `test/fixtures/adr0015_entrypoint.dart`. `dart run` resolves the
// workspace package config by walking up from the sandbox, so no `pub get`
// is needed there.

import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ─── Fixtures (in-process contracts) ─────────────────────────────────────

class _EchoTarget extends Target {
  const _EchoTarget();

  @override
  String get name => 'echo';

  @override
  String get description => 'echoes';

  @override
  List<BuildStep> compile(final BuildContext ctx) => [_EchoStep()];
}

class _EchoStep extends BuildStep {
  static const out = Artifact<String>('echo-out');

  @override
  String get name => 'echo';

  @override
  Set<Artifact<Object>> get provides => {out};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async =>
      StepResult.success({out.id: 'echo'});
}

class _BrokenTarget extends Target {
  const _BrokenTarget();

  @override
  String get name => 'broken';

  @override
  String get description => 'requires an artifact nobody provides';

  @override
  List<BuildStep> compile(final BuildContext ctx) => [_BrokenStep()];
}

class _BrokenStep extends BuildStep {
  static const missing = Artifact<String>('never-provided');

  @override
  String get name => 'broken-step';

  @override
  Set<Artifact<Object>> get requires => {missing};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async =>
      StepResult.success();
}

BuildContext _ctx() => const BuildContext(
      projectPath: '/tmp/oka-test',
      buildDir: '/tmp/oka-test/.oka_cache/build/debug',
      mode: BuildMode.debug,
      config: OkaConfig.empty,
    );

// ─── Target name validation (verb/target collision law) ──────────────────

void main() {
  group('validateTargetName (ADR-0015)', () {
    test('accepts lowercase identifiers', () {
      for (final name in const ['device', 'publish-play', 'a1_b-c', 'x']) {
        expect(validateTargetName(name), isNull, reason: name);
      }
    });

    test('rejects shadowing a reserved core verb — including cache', () {
      final error = validateTargetName('build');
      expect(error, isNotNull);
      expect(error, contains('reserved'));
      // The message names the reserved verbs so the author can pick another.
      expect(error, contains('cache'));
      for (final verb in const ['build', 'run', 'launch', 'init']) {
        expect(validateTargetName(verb), isNotNull, reason: verb);
      }
    });

    test('rejects non-lowercase / non-identifier names', () {
      for (final name in const ['Device', 'Publish Play', '1x', '-x', '']) {
        expect(validateTargetName(name), isNotNull, reason: '"$name"');
      }
    });
  });

  group('validateTargets (composition-time)', () {
    test('rejects duplicate target names', () {
      const oka = Oka(pipelines: [], targets: [_EchoTarget(), _EchoTarget()]);      expect(
        () => validateTargets(oka),
        throwsA(
          isA<TargetResolutionException>().having(
            (final e) => e.message,
            'message',
            contains('duplicate target name "echo"'),
          ),
        ),
      );
    });

    test('rejects a target shadowing a core verb', () {
      expect(
        () => validateTargets(
              const Oka(pipelines: [], targets: [_VerbShadower()]),
            ),
        throwsA(isA<TargetResolutionException>()),
      );
    });
  });

  group('findTarget (ADR-0015 resolution)', () {
    test('resolves a declared target by name', () {
      const oka = Oka(pipelines: [], targets: [_EchoTarget()]);
      expect(findTarget(oka, 'echo').name, 'echo');
    });

    test('unknown name fails naming the available targets', () {
      const oka = Oka(pipelines: [], targets: [_EchoTarget()]);
      expect(
        () => findTarget(oka, 'nope'),
        throwsA(
          isA<TargetResolutionException>().having(
            (final e) => e.message,
            'message',
            allOf(contains('not found'), contains('echo')),
          ),
        ),
      );
    });

    test('no declared targets says so and points at the composition root', () {
      const oka = Oka(pipelines: []);
      expect(
        () => findTarget(oka, 'nope'),
        throwsA(
          isA<TargetResolutionException>().having(
            (final e) => e.message,
            'message',
            allOf(contains('declares no targets'), contains('Oka(targets:')),
          ),
        ),
      );
    });
  });

  group('Target → Pipeline validation (ADR-0015 design law)', () {
    test('a valid target compiles to a pipeline that validates clean', () {
      final pipeline = Pipeline(const _EchoTarget().compile(_ctx()));
      expect(pipeline.validate(), isNull);
    });

    test('an invalid target is caught by Pipeline.validate before running', () {
      final pipeline = Pipeline(const _BrokenTarget().compile(_ctx()));
      final error = pipeline.validate();
      expect(error, isNotNull);
      expect(error, contains('"broken-step"'));
      expect(error, contains('never-provided'));
    });
  });

  // ─── CLI dispatch (subprocess integration) ─────────────────────────────
  group('oka run dispatcher (CLI, sandboxed entrypoint)', () {
    late Directory sandbox;
    late String relBin;

    Future<ProcessResult> okaCli(
      final List<String> args, {
      final String? cwd,
    }) =>
        Process.run(
          'dart',
          ['run', relBin, ...args],
          workingDirectory: cwd ?? sandbox.path,
        );

    setUp(() async {
      sandbox = Directory(
        p.join(
          Directory.current.path,
          '.oka_cache',
          'adr0015_test_${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await Directory(p.join(sandbox.path, 'tool')).create(recursive: true);
      File(p.join(Directory.current.path, 'test/fixtures/adr0015_entrypoint.dart'))
          .copySync(p.join(sandbox.path, 'tool', 'oka_pipeline.dart'));
      relBin = p.relative(
        p.join(Directory.current.path, 'packages', 'oka', 'bin', 'oka.dart'),
        from: sandbox.path,
      );
    });

    tearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    File marker() =>
        File(p.join(sandbox.path, '.oka_cache', 'build', 'debug', 'echo-ran.txt'));

    test('oka run <target> runs the target pipeline', () async {
      final result = await okaCli(['run', 'echo']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(await marker().exists(), isTrue);
    });

    test('a bare unknown verb dispatches to a matching target', () async {
      final result = await okaCli(['echo']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(await marker().exists(), isTrue);
    });

    test('oka run <unknown> fails naming the available targets', () async {
      final result = await okaCli(['run', 'nope']);
      expect(result.exitCode, 1);
      expect(result.stderr, allOf(contains('nope'), contains('echo')));
      expect(await marker().exists(), isFalse);
    });

    test('unknown verb with no matching target lists available targets', () async {
      final result = await okaCli(['frobnicate']);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('Unknown command: frobnicate'));
      expect(result.stderr, allOf(contains('echo'), contains('Test-only')));
      expect(await marker().exists(), isFalse);
    });

    test('oka run with no target prints usage and the target list', () async {
      final result = await okaCli(['run']);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('Usage: oka run <target>'));
      expect(result.stderr, contains('echo'));
    });

    test('unknown verb without an entrypoint points at oka init', () async {
      // Empty sandbox: no tool/oka_pipeline.dart, no oka.yaml.
      final bare = Directory(
        p.join(
          Directory.current.path,
          '.oka_cache',
          'adr0015_bare_${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await bare.create(recursive: true);
      addTearDown(() async {
        if (await bare.exists()) await bare.delete(recursive: true);
      });
      final result = await okaCli(['frobnicate'], cwd: bare.path);
      expect(result.exitCode, 1);
      expect(result.stderr, allOf(contains('frobnicate'), contains('oka init')));
    });
  });

  group('entrypoint target reporting (CLI, fixtures)', () {
    Future<ProcessResult> runFixture(
      final String fixture,
      final List<String> args,
    ) =>
        Process.run('dart', ['run', fixture, ...args],
            workingDirectory: Directory.current.path);

    test('--oka-list-targets reports declared targets as JSON', () async {
      final result = await runFixture(
        'test/fixtures/adr0015_entrypoint.dart',
        ['--oka-list-targets'],
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        jsonDecode(result.stdout as String),
        [
          {
            'name': 'echo',
            'description': 'Test-only no-op target (writes a marker file)',
          },
        ],
      );
    });

    test('invalid target pipeline fails validation before any tool runs', () async {
      final result = await runFixture(
        'test/fixtures/adr0015_broken_target_entrypoint.dart',
        ['--oka-run-target', 'broken'],
      );
      expect(result.exitCode, 1);
      expect(result.stderr, contains('pipeline is invalid'));
      expect(result.stderr, contains('never-provided'));
    });
  });
}

/// A target shadowing a core verb — must be rejected by [validateTargets].
class _VerbShadower extends Target {
  const _VerbShadower();

  @override
  String get name => 'build';

  @override
  String get description => 'illegal: shadows the build verb';

  @override
  List<BuildStep> compile(final BuildContext ctx) => const [];
}
