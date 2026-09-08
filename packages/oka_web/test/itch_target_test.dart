// ADR-0016 W2 — ItchDeployTarget (butler): directory-artifact convention,
// conformance laws, exact butler argv (fake runner, offline, no real butler
// push is ever executed), credential-ref-only key handling, and the
// dry-run/secret-hygiene laws.
import 'dart:io';

import 'package:oka_conformance/oka_conformance.dart';
import 'package:oka_core/oka_core.dart';
import 'package:oka_web/oka_web.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _Call {
  _Call(this.executable, this.arguments, this.workingDirectory, this.environment);
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String>? environment;
}

/// Scripted fake: records every call, returns a scripted outcome.
class _ScriptedRunner implements ProcessRunner {
  _ScriptedRunner(this._handler);

  final ProcOutcome Function(_Call call) _handler;
  final List<_Call> calls = [];

  @override
  Future<ProcOutcome> run(
    final String executable,
    final List<String> arguments, {
    final String? workingDirectory,
    final Map<String, String>? environment,
    final Duration? timeout,
  }) {
    final call = _Call(executable, arguments, workingDirectory, environment);
    calls.add(call);
    return Future<ProcOutcome>.value(_handler(call));
  }

  void assertNoCalls() {
    if (calls.isNotEmpty) fail('unexpected calls: $calls');
  }
}

/// The synthetic key the tests use to prove it never leaks. It guards
/// nothing — like oka_play's `synthetic_credentials.dart`.
const syntheticKey = 'synthetic-butler-key-value';

BuildContext _ctx(
  final Directory tmp, {
  final ProcessRunner? runner,
}) =>
    BuildContext(
      projectPath: tmp.path,
      buildDir: p.join(tmp.path, '.oka_cache', 'build', 'debug'),
      mode: BuildMode.debug,
      config: OkaConfig.empty,
      cacheDir: p.join(tmp.path, '.oka_cache'),
      tempDir: p.join(tmp.path, '.oka_cache', 'build', 'debug', 'temp'),
      processRunner: runner,
    );

Directory _source(final Directory tmp) {
  final dir = Directory(p.join(tmp.path, 'build', 'web'))
    ..createSync(recursive: true);
  File(p.join(dir.path, 'index.html')).writeAsStringSync('<html></html>');
  return dir;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_web_itch_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('shared conformance suite (oka_conformance)', () {
    test('ItchDeployTarget passes the full ADR-0014 suite', () async {
      await expectPublishConformance(
        const ItchDeployTarget(user: 'example-user', game: 'example-game'),
        _ctx(tmp),
        sourcePaths: [p.absolute('lib/src')],
      );
    });

    test('real-mode targets compile + validate but are never executed',
        () async {
      final violations = await auditPublishConformance(
        const ItchDeployTarget(
          dryRun: false,
          user: 'example-user',
          game: 'example-game',
        ),
        _ctx(tmp),
      );
      expect(violations, isEmpty);
    });
  });

  group('directory-artifact convention + plan shape', () {
    test('artifactIsDirectory is declared and flows into the plan',
        () async {
      const target = ItchDeployTarget(user: 'u', game: 'g');
      expect(target.artifactIsDirectory, isTrue);
      final state = PipelineState();
      final result =
          await Pipeline(target.compile(_ctx(tmp))).run(_ctx(tmp),
              initialState: state);
      expect(result.ok, isTrue, reason: result.error);
      final plan = state[PublishPlanStep.plan.id]! as PublishPlan;
      expect(plan.artifactIsDirectory, isTrue);
      expect(plan.describeLines().join('\n'), contains('(directory)'));
    });

    test('the dry-run plan has the exact itch shape', () async {
      const target = ItchDeployTarget(user: 'example-user', game: 'my-game');
      final state = PipelineState();
      final result = await Pipeline(target.compile(_ctx(tmp)))
          .run(_ctx(tmp), initialState: state);
      expect(result.ok, isTrue, reason: result.error);
      final plan = state[PublishPlanStep.plan.id]! as PublishPlan;
      expectPlanShape(
        plan,
        target: 'publish-itch',
        endpoint: 'itch.io (butler push)',
        track: 'web',
        artifactId: 'web-build-output',
        dryRun: true,
        exactMetadata: true,
        metadata: const {
          'user': 'example-user',
          'game': 'my-game',
          'channel': 'web',
        },
        credentials: [target.apiKeyRef],
      );
      expectPlanDescribes(plan, [
        'target: publish-itch (dry run — nothing was uploaded)',
        'artifact: web-build-output',
        '(directory)',
        // Credential refs render redacted — never the env var value.
        'credential: CredentialRef(itch/butler-api-key → [redacted])',
      ]);
    });

    test('dry run succeeds with no credentials and runs zero commands',
        () async {
      final runner = _ScriptedRunner((final _) => fail('must not run butler'));
      final state = PipelineState();
      final result =
          await Pipeline(const ItchDeployTarget(user: 'u', game: 'g')
                  .compile(_ctx(tmp, runner: runner)))
              .run(_ctx(tmp, runner: runner), initialState: state);
      expect(result.ok, isTrue, reason: result.error);
      runner.assertNoCalls();
    });
  });

  group('real mode — exact butler argv (scripted, no real push)', () {
    test('push argv is exact: butler push DIR USER/GAME:CHANNEL', () async {
      final source = _source(tmp);
      final target = ItchDeployTarget(
        dryRun: false,
        user: 'example-user',
        game: 'my-game',
        channel: 'html5',
        sourceDir: source.path,
      );
      final runner = _ScriptedRunner((final _) => const ProcOutcome(
            exitCode: 0,
            stdout: 'pushed to example-user/my-game:html5',
            stderr: '',
          ));
      final state = PipelineState();
      final result = await Pipeline([
        StageWebDirectoryStep(
          artifactId: target.directoryArtifactId,
          sourceDir: source.path,
        ),
        ButlerUploadStep(
          target,
          environment: {'BUTLER_API_KEY': syntheticKey},
        ),
      ]).run(_ctx(tmp, runner: runner), initialState: state);
      expect(result.ok, isTrue, reason: result.error);
      expect(runner.calls, hasLength(1));
      expect(
        [runner.calls.first.executable, ...runner.calls.first.arguments],
        [
          'butler',
          'push',
          source.path,
          'example-user/my-game:html5',
        ],
        reason: 'executable + arguments are the exact butler push argv',
      );
      // The key is passed to the child-process environment only.
      expect(
        runner.calls.first.environment!['BUTLER_API_KEY'],
        syntheticKey,
      );
    });
  });

  group('credential hygiene (law 3)', () {
    test('no secret value in state, step data, or plan', () async {
      final source = _source(tmp);
      final target = ItchDeployTarget(
        dryRun: false,
        user: 'example-user',
        game: 'my-game',
        sourceDir: source.path,
      );
      final runner = _ScriptedRunner((final _) =>
          const ProcOutcome(exitCode: 0, stdout: 'ok', stderr: ''));
      final state = PipelineState();
      final result = await Pipeline([
        StageWebDirectoryStep(
          artifactId: target.directoryArtifactId,
          sourceDir: source.path,
        ),
        ButlerUploadStep(
          target,
          environment: {'BUTLER_API_KEY': syntheticKey},
        ),
      ]).run(_ctx(tmp, runner: runner), initialState: state);
      expect(result.ok, isTrue, reason: result.error);
      // The synthetic value must appear nowhere in state or step data.
      final dump =
          '${state.snapshot}\n${result.data}${target.plan(_ctx(tmp), artifactPath: 'x')}';
      expect(dump.contains(syntheticKey), isFalse);
      expectStateRedacted(state, refs: [target.apiKeyRef]);
    });

    test('no credentials in real mode → actionable failure, no execution',
        () async {
      final source = _source(tmp);
      final target = ItchDeployTarget(
        dryRun: false,
        user: 'example-user',
        game: 'my-game',
        sourceDir: source.path,
      );
      final runner =
          _ScriptedRunner((final _) => fail('must not run butler'));
      final state = PipelineState();
      final result = await Pipeline([
        StageWebDirectoryStep(
          artifactId: target.directoryArtifactId,
          sourceDir: source.path,
        ),
        ButlerUploadStep(target, environment: const {}),
      ]).run(_ctx(tmp, runner: runner), initialState: state);
      expect(result.ok, isFalse);
      expect(result.error, contains('no butler API key resolved'));
      expect(result.error, contains('BUTLER_API_KEY'));
      runner.assertNoCalls();
    });

    test('explicit API-key file path is read by path, value passed via env',
        () async {
      final source = _source(tmp);
      final keyFile = File(p.join(tmp.path, 'key.txt'))
        ..writeAsStringSync('$syntheticKey\n');
      final target = ItchDeployTarget(
        dryRun: false,
        user: 'example-user',
        game: 'my-game',
        sourceDir: source.path,
        apiKeyPath: keyFile.path,
      );
      final runner = _ScriptedRunner((final _) =>
          const ProcOutcome(exitCode: 0, stdout: 'ok', stderr: ''));
      final state = PipelineState();
      final result = await Pipeline([
        StageWebDirectoryStep(
          artifactId: target.directoryArtifactId,
          sourceDir: source.path,
        ),
        // No key in the env: the typed-config file is the only source.
        ButlerUploadStep(target, environment: const {}),
      ]).run(_ctx(tmp, runner: runner), initialState: state);
      expect(result.ok, isTrue, reason: result.error);
      expect(
        runner.calls.first.environment!['BUTLER_API_KEY'],
        syntheticKey, // file content, whitespace-trimmed
      );
      // The key file path is location data — it may name the source in the
      // failure text only; values never leak. Assert the value is absent.
      expect(result.data.toString().contains(syntheticKey), isFalse);
    });

    test('well-known location resolves last', () async {
      final source = _source(tmp);
      final home = Directory(p.join(tmp.path, 'home'))
        ..createSync(recursive: true);
      final wellKnown = Directory(p.join(
        home.path,
        '.oka',
        'credentials',
        'itch',
      ))..createSync(recursive: true);
      File(p.join(wellKnown.path, 'butler-api-key'))
          .writeAsStringSync(syntheticKey);
      final target = ItchDeployTarget(
        dryRun: false,
        user: 'example-user',
        game: 'my-game',
        sourceDir: source.path,
      );
      final runner = _ScriptedRunner((final _) =>
          const ProcOutcome(exitCode: 0, stdout: 'ok', stderr: ''));
      final state = PipelineState();
      final result = await Pipeline([
        StageWebDirectoryStep(
          artifactId: target.directoryArtifactId,
          sourceDir: source.path,
        ),
        ButlerUploadStep(target, environment: {'HOME': home.path}),
      ]).run(_ctx(tmp, runner: runner), initialState: state);
      expect(result.ok, isTrue, reason: result.error);
      expect(
        runner.calls.first.environment!['BUTLER_API_KEY'],
        syntheticKey,
      );
    });
  });

  group('typed-config validation', () {
    test('rejects spaces/shell metacharacters with actionable errors', () {
      final issues = const ItchDeployTarget(
        user: 'my user',
        game: 'my game',
        channel: 'web;rm -rf',
      ).validateConfig();
      final joined = issues.join(' ');
      expect(joined, contains('user'));
      expect(joined, contains('game'));
      expect(joined, contains('channel'));

      expect(
        const ItchDeployTarget(user: '', game: 'g').validateConfig().join(' '),
        contains('user'),
      );
      expect(
        const ItchDeployTarget(
          user: 'u',
          game: 'g',
          butlerBinary: 'butler;echo',
        ).validateConfig().join(' '),
        contains('butlerBinary'),
      );
      expect(
        const ItchDeployTarget(user: 'ok-user', game: 'My_Game.2')
            .validateConfig(),
        isEmpty,
      );
    });
  });
}
