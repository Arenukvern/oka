// ADR-0015 C2 — `oka explain --targets`.
//
// Covers:
// * the entrypoint machine mode (`--oka-describe-targets`) reporting compiled,
//   validated step chains as JSON — with no execution;
// * `oka explain --targets` CLI output: target name, description, step chain
//   with requires/provides summaries, and composition-time validation status;
// * **no tool invocation** in the explain path (a target whose steps would
//   write a marker file is described but never run);
// * the entrypoint-less project case (points at `oka init`);
// * regression: plain `oka explain` (non-flags path) output is unchanged —
//   build-plan sections present, no target listing.
//
// The CLI tests run the real CLI (`dart run bin/oka.dart …`) against sandbox
// projects under `.oka_cache/` (gitignored) whose entrypoints are the test
// fixtures, mirroring test/adr0015_target_dispatch_test.dart.

import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('--oka-describe-targets (entrypoint machine mode)', () {
    Future<ProcessResult> runFixture(
      final String fixture,
      final List<String> args,
    ) =>
        Process.run('dart', ['run', fixture, ...args],
            workingDirectory: Directory.current.path);

    test('reports compiled step chains as JSON (names + artifacts)', () async {
      final result = await runFixture(
        'test/fixtures/adr0015_chain_target_entrypoint.dart',
        ['--oka-describe-targets'],
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        jsonDecode(result.stdout as String),
        [
          {
            'name': 'chain',
            'description': 'Test-only two-step target (assemble → sign)',
            'steps': [
              {
                'name': 'chain-assemble',
                'requires': <String>[],
                'provides': ['chain-out'],
              },
              {
                'name': 'chain-sign',
                'requires': ['chain-out'],
                'provides': <String>[],
              },
            ],
            // ADR-0016 W1: pure explain details ride the same report.
            'details': ['test detail: pure composition line'],
            'validationError': null,
          },
        ],
      );
    });

    test('reports composition-time validation failures without running',
        () async {
      final result = await runFixture(
        'test/fixtures/adr0015_broken_target_entrypoint.dart',
        ['--oka-describe-targets'],
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final described = (jsonDecode(result.stdout as String) as List)
          .map((final e) => TargetChainDescription.fromJson(
                (e as Map).cast<String, dynamic>(),
              ))
          .toList();
      expect(described, hasLength(1));
      expect(described.single.name, 'broken');
      expect(described.single.isValid, isFalse);
      expect(
        described.single.validationError,
        allOf(contains('broken-step'), contains('never-provided')),
      );
    });

    test('is pure: describeTarget matches the entrypoint report', () {
      const ctx = BuildContext(
        projectPath: '/tmp/oka-test',
        buildDir: '/tmp/oka-test/.oka_cache/build/debug',
        mode: BuildMode.debug,
        config: OkaConfig.empty,
      );
      final described = describeTarget(const _ChainTarget(), ctx);
      expect(described.isValid, isTrue);
      expect(described.steps.map((final s) => s.name).toList(),
          ['chain-assemble', 'chain-sign']);
      expect(described.steps[0].provides, ['chain-out']);
      expect(described.steps[1].requires, ['chain-out']);
      // ADR-0016 W1: explainDetails flows through describeTarget; the
      // default is empty (targets that need no details need no override).
      expect(described.details, ['test detail: pure composition line']);
      expect(
        describeTarget(const _PlainTarget(), ctx).details,
        isEmpty,
      );
    });
  });

  group('oka explain --targets (CLI, sandboxed entrypoint)', () {
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
          'adr0015_explain_test_${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await Directory(p.join(sandbox.path, 'tool')).create(recursive: true);
      File(
        p.join(
          Directory.current.path,
          'test/fixtures/adr0015_entrypoint.dart',
        ),
      ).copySync(p.join(sandbox.path, 'tool', 'oka_pipeline.dart'));
      relBin = p.relative(
        p.join(Directory.current.path, 'bin', 'oka.dart'),
        from: sandbox.path,
      );
    });

    tearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    File marker() => File(
          p.join(sandbox.path, '.oka_cache', 'build', 'debug', 'echo-ran.txt'),
        );

    test('lists declared targets with their step chains', () async {
      final result = await okaCli(['explain', '--targets']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final out = result.stdout as String;
      // Header + entrypoint discovery.
      expect(out, allOf(contains('project targets'), contains('no tools')));
      expect(out, contains('tool/oka_pipeline.dart'));
      // Target name + description + step chain + validation status.
      expect(out, contains('echo'));
      expect(out, contains('Test-only no-op target'));
      expect(out, contains('artifact chain valid'));
      // ADR-0016 W1: the target's pure explain details are printed
      // verbatim (the CLI never interprets them).
      expect(out, contains('details:'));
      expect(out, contains('test detail: pure explain line'));
    });

    test('describes but never executes targets (no tool invocation)',
        () async {
      final result = await okaCli(['explain', '--targets']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      // The fixture target's step writes this marker when it *runs*; the
      // explain path must only describe the chain.
      expect(await marker().exists(), isFalse);
    });

    test('reports a composition-time validation failure without running',
        () async {
      File(
        p.join(
          Directory.current.path,
          'test/fixtures/adr0015_broken_target_entrypoint.dart',
        ),
      ).copySync(p.join(sandbox.path, 'tool', 'oka_pipeline.dart'));
      final result = await okaCli(['explain', '--targets']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final out = result.stdout as String;
      expect(out, contains('broken'));
      expect(out, allOf(contains('broken-step'), contains('never-provided')));
      expect(await marker().exists(), isFalse);
    });

    test('plain oka explain output is unchanged (no target listing)',
        () async {
      final result = await okaCli(['explain']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final out = result.stdout as String;
      // The non-flags path still reports the build plan…
      expect(out, allOf(contains('build plan'), contains('── Pipeline')));
      expect(out, contains('── Validation'));
      expect(out, contains('Dry-run complete'));
      // …including the entrypoint-hook notice, but no target listing.
      expect(out, contains('dart pipeline:'));
      expect(out, isNot(contains('project targets')));
    });

    test('without an entrypoint points at oka init', () async {
      final bare = Directory(
        p.join(
          Directory.current.path,
          '.oka_cache',
          'adr0015_explain_bare_${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await bare.create(recursive: true);
      addTearDown(() async {
        if (await bare.exists()) await bare.delete(recursive: true);
      });
      final result = await okaCli(['explain', '--targets'], cwd: bare.path);
      expect(result.exitCode, 1);
      expect(
        result.stderr,
        allOf(contains('explain --targets'), contains('oka init')),
      );
    });
  });
}

/// Local multi-step target mirroring the chain fixture, for the pure
/// [describeTarget] contract test.
class _ChainTarget extends Target {
  const _ChainTarget();

  @override
  String get name => 'chain';

  @override
  String get description => 'test chain';

  @override
  List<BuildStep> compile(final BuildContext ctx) =>
      [_AssembleStep(), _SignStep()];

  @override
  List<String> explainDetails(final BuildContext ctx) =>
      const ['test detail: pure composition line'];
}

/// A target with no explainDetails override — the default is no details.
class _PlainTarget extends Target {
  const _PlainTarget();

  @override
  String get name => 'plain';

  @override
  String get description => 'test plain';

  @override
  List<BuildStep> compile(final BuildContext ctx) => [_AssembleStep()];
}

class _AssembleStep extends BuildStep {
  static const out = Artifact<String>('chain-out');

  @override
  String get name => 'chain-assemble';

  @override
  Set<Artifact<Object>> get provides => {out};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) =>
      Future.value(StepResult.success());
}

class _SignStep extends BuildStep {
  static const input = Artifact<String>('chain-out');

  @override
  String get name => 'chain-sign';

  @override
  Set<Artifact<Object>> get requires => {input};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) =>
      Future.value(StepResult.success());
}
