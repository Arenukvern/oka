// ADR-0016 W2 — GhPagesDeployTarget: directory-artifact convention,
// conformance laws, exact git argv sequences (fake runner, offline, no real
// git push is ever executed), and the dry-run/secret-hygiene laws.
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

  @override
  String toString() => '$executable ${arguments.join(' ')} '
      '(cwd: $workingDirectory)';
}

/// Scripted fake: routes by the first git subcommand; records every call.
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

  List<List<String>> get argv =>
      calls.map((final c) => [c.executable, ...c.arguments]).toList();

  void assertNoCalls() {
    if (calls.isNotEmpty) fail('unexpected calls: $calls');
  }
}

const ProcOutcome _ok = ProcOutcome(exitCode: 0, stdout: '', stderr: '');

ProcOutcome _okOut(final String stdout) =>
    ProcOutcome(exitCode: 0, stdout: stdout, stderr: '');

BuildContext _ctx(final Directory tmp, {final ProcessRunner? runner}) =>
    BuildContext(
      projectPath: tmp.path,
      buildDir: p.join(tmp.path, '.oka_cache', 'build', 'debug'),
      mode: BuildMode.debug,
      config: OkaConfig.empty,
      cacheDir: p.join(tmp.path, '.oka_cache'),
      tempDir: p.join(tmp.path, '.oka_cache', 'build', 'debug', 'temp'),
      processRunner: runner,
    );

/// Creates a source directory with content (including a `.git` entry that
/// must never be copied by the content sync).
Directory _source(final Directory tmp) {
  final dir = Directory(p.join(tmp.path, 'source'))
    ..createSync(recursive: true);
  File(p.join(dir.path, 'index.html')).writeAsStringSync('<html></html>');
  Directory(p.join(dir.path, 'assets')).createSync();
  File(p.join(dir.path, 'assets', 'app.js')).writeAsStringSync('// js');
  Directory(p.join(dir.path, '.git')).createSync();
  File(p.join(dir.path, '.git', 'HEAD')).writeAsStringSync('ref: main');
  return dir;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_web_gh_pages_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('shared conformance suite (oka_conformance)', () {
    test('GhPagesDeployTarget passes the full ADR-0014 suite', () async {
      await expectPublishConformance(
        const GhPagesDeployTarget(),
        _ctx(tmp),
        sourcePaths: [p.absolute('lib/src')],
      );
    });

    test('real-mode targets compile + validate but are never executed',
        () async {
      final violations = await auditPublishConformance(
        const GhPagesDeployTarget(dryRun: false),
        _ctx(tmp),
      );
      expect(violations, isEmpty);
    });
  });

  group('directory-artifact convention (ADR-0016 §2)', () {
    test('artifactIsDirectory is declared and flows into the plan',
        () async {
      const target = GhPagesDeployTarget();
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

    test('conformance passes when the artifact path is a real directory',
        () async {
      final source = _source(tmp);
      final violations = await auditPublishConformance(
        GhPagesDeployTarget(dryRun: false, sourceDir: source.path),
        _ctx(tmp),
      );
      expect(violations, isEmpty);
    });

    test('conformance fails when the artifact path is a file', () async {
      final file = File(p.join(tmp.path, 'not-a-dir.txt'))
        ..writeAsStringSync('x');
      final violations = await auditPublishConformance(
        GhPagesDeployTarget(sourceDir: file.path),
        _ctx(tmp),
      );
      expect(violations.join('\n'), contains('directory-artifact convention'));
    });

    test('dry run succeeds without any built directory (law 1)', () async {
      final state = PipelineState();
      final result =
          await Pipeline(const GhPagesDeployTarget().compile(_ctx(tmp)))
              .run(_ctx(tmp), initialState: state);
      expect(result.ok, isTrue, reason: result.error);
    });
  });

  group('dry-run law — no command execution', () {
    test('the dry-run chain is [stage-web-dir, publish-plan] — no git',
        () {
      final chain = describeTarget(const GhPagesDeployTarget(), _ctx(tmp));
      expect(chain.isValid, isTrue, reason: chain.validationError);
      expect(
        chain.steps.map((final s) => s.name).toList(),
        ['stage-web-dir', 'publish-plan'],
      );
    });

    test('dry run performs zero command execution (canary runner)',
        () async {
      final runner = _ScriptedRunner((final _) => fail('must not run git'));
      final state = PipelineState();
      final result =
          await Pipeline(const GhPagesDeployTarget().compile(_ctx(tmp, runner: runner)))
              .run(_ctx(tmp, runner: runner), initialState: state);
      expect(result.ok, isTrue, reason: result.error);
      runner.assertNoCalls();
    });

    test('the dry-run plan has the exact gh-pages shape', () async {
      const target = GhPagesDeployTarget();
      final state = PipelineState();
      final result = await Pipeline(target.compile(_ctx(tmp)))
          .run(_ctx(tmp), initialState: state);
      expect(result.ok, isTrue, reason: result.error);
      final plan = state[PublishPlanStep.plan.id]! as PublishPlan;
      expectPlanShape(
        plan,
        target: 'publish-gh-pages',
        endpoint: 'GitHub Pages (git push to origin/gh-pages)',
        track: 'gh-pages',
        artifactId: 'web-build-output',
        dryRun: true,
        exactMetadata: true,
        metadata: const {'branch': 'gh-pages', 'remote': 'origin'},
        credentials: const [],
      );
      expectPlanDescribes(plan, [
        'target: publish-gh-pages (dry run — nothing was uploaded)',
        'artifact: web-build-output',
        '(directory)',
      ]);
    });
  });

  group('real mode — exact argv sequences (scripted git, no real push)', () {
    test('first deploy: orphan branch path — exact argv sequence', () async {
      final source = _source(tmp);
      final target = GhPagesDeployTarget(dryRun: false, sourceDir: source.path);
      final runner = _ScriptedRunner((final call) => switch (call.arguments.first) {
          'rev-parse' => const ProcOutcome(exitCode: 128, stdout: '', stderr: ''),
          'fetch' => const ProcOutcome(exitCode: 128, stdout: '', stderr: ''),
          'status' => _okOut('A  index.html\n'),
          _ => _ok,
      });
      final state = PipelineState();
      final result =
          await Pipeline(target.compile(_ctx(tmp, runner: runner)))
              .run(_ctx(tmp, runner: runner), initialState: state);
      expect(result.ok, isTrue, reason: result.error);

      final worktreeDir =
          p.join(_ctx(tmp).buildDir, 'gh-pages', 'worktree');
      expect(
        runner.argv,
        [
          ['git', 'rev-parse', '--verify', '--quiet', 'origin/gh-pages'],
          ['git', 'fetch', 'origin', 'gh-pages'],
          // The fetch failure short-circuits the retry (the remote branch
          // is unknown) — first deploy proceeds on the orphan path.
          ['git', 'worktree', 'add', '--detach', worktreeDir, 'HEAD'],
          ['git', 'checkout', '--orphan', 'gh-pages'],
          ['git', 'add', '-A'],
          ['git', 'status', '--porcelain'],
          [
            'git',
            'commit',
            '-m',
            'Deploy web build (oka publish-gh-pages)',
          ],
          ['git', 'push', 'origin', 'HEAD:refs/heads/gh-pages'],
          ['git', 'worktree', 'remove', '--force', worktreeDir],
          ['git', 'worktree', 'prune'],
        ],
        reason: runner.calls.map((final c) => c.toString()).join('\n'),
      );

      // cwd discipline: repo-level commands run in the project, worktree
      // commands inside the worktree.
      final callByArg = {
        for (final c in runner.calls) c.arguments.first: c,
      };
      expect(
        callByArg['rev-parse']!.workingDirectory,
        tmp.path,
      );
      expect(callByArg['checkout']!.workingDirectory, worktreeDir);
      expect(callByArg['commit']!.workingDirectory, worktreeDir);
      expect(callByArg['push']!.workingDirectory, worktreeDir);

      // No interactive prompts, ever: the child git env disables prompts.
      expect(
        callByArg['push']!.environment!['GIT_TERMINAL_PROMPT'],
        '0',
      );

      // Content sync happened in the worktree: source content present,
      // the `.git` entry never copied.
      expect(
        File(p.join(worktreeDir, 'index.html')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(worktreeDir, 'assets', 'app.js')).existsSync(),
        isTrue,
      );
      expect(Directory(p.join(worktreeDir, '.git')).existsSync(), isFalse);
    });

    test('existing remote branch: worktree on the remote branch, no fetch',
        () async {
      final source = _source(tmp);
      final target = GhPagesDeployTarget(dryRun: false, sourceDir: source.path);
      final runner = _ScriptedRunner((final call) => switch (call.arguments.first) {
          'rev-parse' => _ok,
          'status' => _okOut('M  index.html\n'),
          _ => _ok,
      });
      final state = PipelineState();
      final result =
          await Pipeline(target.compile(_ctx(tmp, runner: runner)))
              .run(_ctx(tmp, runner: runner), initialState: state);
      expect(result.ok, isTrue, reason: result.error);

      final worktreeDir =
          p.join(_ctx(tmp).buildDir, 'gh-pages', 'worktree');
      final worktreeAdds = runner.calls
          .where((final c) => c.arguments.take(2).join(' ') == 'worktree add')
          .toList();
      expect(worktreeAdds, hasLength(1));
      expect(
        worktreeAdds.single.arguments,
        ['worktree', 'add', '--detach', worktreeDir, 'origin/gh-pages'],
      );
      expect(
        runner.calls.map((final c) => c.arguments.first),
        isNot(contains('fetch')),
      );
      expect(
        runner.calls.map((final c) => c.arguments.first),
        isNot(contains('checkout')),
      );
    });

    test('allow-empty false: identical content fails actionably, no push',
        () async {
      final source = _source(tmp);
      final target = GhPagesDeployTarget(dryRun: false, sourceDir: source.path);
      final runner = _ScriptedRunner((final call) => switch (call.arguments.first) {
          'rev-parse' => _ok,
          'status' => _okOut(''),
          _ => _ok,
      });
      final state = PipelineState();
      final result =
          await Pipeline(target.compile(_ctx(tmp, runner: runner)))
              .run(_ctx(tmp, runner: runner), initialState: state);
      expect(result.ok, isFalse);
      expect(
        result.error,
        contains('nothing to publish'),
      );
      expect(
        runner.calls.map((final c) => c.arguments.first),
        isNot(contains('push')),
      );
      expect(
        runner.calls.map((final c) => c.arguments.first),
        isNot(contains('commit')),
      );
    });

    test('subdirectory filter publishes only the subdirectory', () async {
      final source = _source(tmp);
      final target = GhPagesDeployTarget(
        dryRun: false,
        sourceDir: source.path,
        subdirectory: 'assets',
      );
      final runner = _ScriptedRunner((final call) => switch (call.arguments.first) {
          'rev-parse' => _ok,
          'status' => _okOut('A  app.js\n'),
          _ => _ok,
      });
      final state = PipelineState();
      final result =
          await Pipeline(target.compile(_ctx(tmp, runner: runner)))
              .run(_ctx(tmp, runner: runner), initialState: state);
      expect(result.ok, isTrue, reason: result.error);
      final worktreeDir =
          p.join(_ctx(tmp).buildDir, 'gh-pages', 'worktree');
      expect(File(p.join(worktreeDir, 'app.js')).existsSync(), isTrue);
      expect(File(p.join(worktreeDir, 'index.html')).existsSync(), isFalse);
    });

    test('missing source directory fails actionably before any git',
        () async {
      final target = GhPagesDeployTarget(
        dryRun: false,
        sourceDir: p.join(tmp.path, 'does-not-exist'),
      );
      final runner = _ScriptedRunner((final _) => fail('must not run git'));
      final state = PipelineState();
      final result =
          await Pipeline(target.compile(_ctx(tmp, runner: runner)))
              .run(_ctx(tmp, runner: runner), initialState: state);
      expect(result.ok, isFalse);
      expect(result.error, contains('does not exist'));
      runner.assertNoCalls();
    });
  });

  group('typed-config validation', () {
    test('rejects unsafe branch/remote names with actionable errors', () {
      final issues = const GhPagesDeployTarget(
        branch: 'gh pages',
        remote: r'origin$(x)',
      ).validateConfig();
      expect(issues.join(' '), contains('branch'));
      expect(issues.join(' '), contains('remote'));

      expect(
        const GhPagesDeployTarget(branch: '-evil').validateConfig().join(' '),
        contains('branch'),
      );
      expect(
        const GhPagesDeployTarget(branch: 'a..b').validateConfig().join(' '),
        contains('branch'),
      );
      expect(
        const GhPagesDeployTarget(
          subdirectory: '../escape',
        ).validateConfig().join(' '),
        contains('subdirectory'),
      );
      expect(const GhPagesDeployTarget().validateConfig(), isEmpty);
    });
  });
}
