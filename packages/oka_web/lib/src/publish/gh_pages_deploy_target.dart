/// The `publish-gh-pages` target (ADR-0016 W2): deploy a **directory**
/// artifact to GitHub Pages by pushing a commit to a `gh-pages` branch.
///
/// Auth model: **ambient git credentials only** — no token inputs, no
/// credential files, no interactive input. Whatever `git push` resolves on
/// the build host (ssh agent, credential helper) is what authenticates.
///
/// Composition (ADR-0016 §2, targets not pipelines): the target consumes
/// the directory artifact produced by an oka web build chain —
///
/// ```dart
/// // Simplest: the target stages `build/web` (Flutter's default output)
/// // itself; run `flutter build web` (oka `web-build`) first.
/// targets: [
///   WebBuildTarget(baseHref: '/my-app/'),
///   GhPagesDeployTarget(
///     // dryRun: false,  // deploys are destructive — explicit flip
///   ),
/// ]
///
/// // Fully composed: one chain that builds then deploys — declare a
/// // custom Target in your entrypoint and reuse the deploy tail:
/// Target(
///   name: 'web-deploy',
///   description: 'flutter build web + push to gh-pages',
///   compile: (ctx) => [
///     FlutterWebBuildStep(baseHref: '/my-app/'),
///     ...const GhPagesDeployTarget(dryRun: false).compile(ctx),
///   ],
/// )
/// ```
///
/// The target is **independently composable** — it never runs a Flutter
/// build itself and never couples to `WebShellTarget`; point [sourceDir]
/// (typed config) or the [directoryArtifactId] artifact at any directory
/// you want to publish.
///
/// Why [dryRun] defaults to `true` here (unlike the `PublishTarget` field
/// default): this deploy is **destructive and push-based** — it rewrites a
/// remote branch — and its auth is ambient, so a misconfigured run can
/// succeed end-to-end without any explicit credential step. A real push
/// must always be an explicit decision (`dryRun: false` in typed config).
library;

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import 'stage_web_dir_step.dart';

/// The `publish-gh-pages` [PublishTarget].
@immutable
class GhPagesDeployTarget extends PublishTarget {
  const GhPagesDeployTarget({
    this.dryRun = true,
    this.directoryArtifactId = StageWebDirectoryStep.defaultDirectoryArtifactId,
    this.sourceDir,
    this.branch = 'gh-pages',
    this.commitMessage = 'Deploy web build (oka publish-gh-pages)',
    this.remote = 'origin',
    this.subdirectory,
  });

  /// Typed dry-run flag — `true` by default. Deploys are destructive: the
  /// upload tail rewrites the remote [branch] via `git push`, and auth is
  /// ambient (no explicit credential step stands between you and the
  /// push), so a real push is always an explicit, deliberate flip.
  @override
  final bool dryRun;

  /// The directory artifact id this target consumes (default:
  /// `web-build-output`, produced by `FlutterWebBuildStep`).
  final String directoryArtifactId;

  /// Explicit source directory override (typed config). Null → the staged
  /// state artifact → `<project>/build/web`.
  final String? sourceDir;

  /// Branch to push to (default `gh-pages`). Validated by
  /// [validateConfig] — a safe git ref name, no shell metacharacters.
  final String branch;

  /// Commit message for the deployment commit.
  final String commitMessage;

  /// Git remote to fetch from and push to (default `origin`).
  final String remote;

  /// Optional subdirectory filter — publish only this subdirectory of the
  /// source directory (e.g. `web` when the artifact is the project root).
  /// Must be a relative path without `..` segments.
  final String? subdirectory;

  @override
  bool get artifactIsDirectory => true;

  @override
  String get name => 'publish-gh-pages';

  @override
  String get description =>
      'Push the web build directory to GitHub Pages ($remote/$branch, '
      'ambient git auth${dryRun ? ', dry run' : ''})';

  @override
  String get endpoint => 'GitHub Pages (git push to $remote/$branch)';

  @override
  String get track => branch;

  @override
  String get artifactId => directoryArtifactId;

  @override
  Map<String, String> get metadata => {
        'branch': branch,
        'remote': remote,
        if (subdirectory != null && subdirectory!.isNotEmpty)
          'subdirectory': subdirectory!,
      };

  @override
  List<BuildStep> publishSteps(final BuildContext ctx) => [
        StageWebDirectoryStep(
          artifactId: directoryArtifactId,
          sourceDir: sourceDir,
        ),
      ];

  @override
  BuildStep uploadStep(final BuildContext ctx) => GhPagesUploadStep(this);

  /// Typed-config validation issues (empty = valid). Pure. Git receives
  /// [branch]/[remote] as separate argv elements (no shell), but refs and
  /// remotes with spaces, leading dashes, or shell metacharacters are
  /// rejected anyway — a mistyped config should fail at composition time,
  /// not produce a surprising remote call.
  List<String> validateConfig() {
    final issues = <String>[];
    if (branch.isEmpty) {
      issues.add('branch is empty — set the target branch, e.g. "gh-pages"');
    } else if (!_gitRefPattern.hasMatch(branch) || branch.contains('..')) {
      issues.add(
        'branch "$branch" is not a safe git ref name — use letters, digits, '
        'dots, dashes, slashes (no spaces, no leading dash, no ".."), '
        'e.g. "gh-pages"',
      );
    }
    if (remote.isEmpty) {
      issues.add('remote is empty — set the git remote, e.g. "origin"');
    } else if (!_gitRemotePattern.hasMatch(remote)) {
      issues.add(
        'remote "$remote" is not a safe remote name — use letters, digits, '
        'dots, dashes, underscores (no spaces, no leading dash), '
        'e.g. "origin"',
      );
    }
    if (commitMessage.isEmpty) {
      issues.add(
        'commitMessage is empty — a deployment commit needs a message',
      );
    }
    final sub = subdirectory;
    if (sub != null && sub.isNotEmpty) {
      if (p.isAbsolute(sub) ||
          sub.split('/').contains('..') ||
          sub.contains(r'\')) {
        issues.add(
          'subdirectory "$sub" must be a relative path inside the source '
          'directory (no absolute paths, no ".." segments)',
        );
      }
    }
    return issues;
  }

  @override
  String toString() => 'GhPagesDeployTarget($remote/$branch'
      '${dryRun ? ' [dry-run]' : ''})';
}

/// Safe git ref name: letters/digits then letters, digits, `.`, `-`, `_`,
/// `/`. No spaces, no shell metacharacters, no leading dash.
final RegExp _gitRefPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/-]*$');

/// Safe remote name (no `/` — that is a ref namespace separator).
final RegExp _gitRemotePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

/// Pure git command builders (extensions on [GhPagesDeployTarget]).
///
/// Every git invocation is a separate argv (no shell anywhere — oka never
/// spawns a shell), so values cannot smuggle metacharacters; the typed
/// [GhPagesDeployTarget.validateConfig] rejects unsafe names earlier with
/// actionable errors.
extension GhPagesGitCommands on GhPagesDeployTarget {
  /// Does the remote-tracking ref exist locally?
  List<String> verifyRemoteBranchArgs() =>
      ['rev-parse', '--verify', '--quiet', '$remote/$branch'];

  /// Refresh the remote-tracking ref for [branch].
  List<String> fetchBranchArgs() => ['fetch', remote, branch];

  /// Existing branch: check out the remote branch detached in a temp
  /// worktree (`<worktreeDir>`).
  List<String> worktreeAddRemoteBranchArgs(final String worktreeDir) =>
      ['worktree', 'add', '--detach', worktreeDir, '$remote/$branch'];

  /// First deploy (no remote branch yet): detach on the current HEAD; the
  /// step then creates an orphan branch inside the worktree.
  List<String> worktreeAddHeadArgs(final String worktreeDir) =>
      ['worktree', 'add', '--detach', worktreeDir, 'HEAD'];

  /// First deploy: orphan branch (no history carried over).
  List<String> checkoutOrphanArgs() => ['checkout', '--orphan', branch];

  /// Stage everything (including deletions from the content sync).
  List<String> addAllArgs() => ['add', '-A'];

  /// Detect a content change (allow-empty is false as code: empty output
  /// → the deploy step fails actionably instead of committing nothing).
  List<String> statusPorcelainArgs() => ['status', '--porcelain'];

  List<String> commitArgs() => ['commit', '-m', commitMessage];

  List<String> pushArgs() => ['push', remote, 'HEAD:refs/heads/$branch'];

  List<String> worktreeRemoveArgs(final String worktreeDir) =>
      ['worktree', 'remove', '--force', worktreeDir];

  List<String> worktreePruneArgs() => ['worktree', 'prune'];
}

/// The real upload tail: sync the source directory into a temporary
/// worktree of the [remote]/[branch] checkout and push the deployment
/// commit.
///
/// Sequence (every call through `ctx.runner`, no shell, no interactive
/// input, ambient git auth — no token inputs ever):
///
/// 1. `rev-parse --verify --quiet REMOTE/BRANCH` — is the remote branch
///    known locally?
/// 2. Not known: `fetch REMOTE BRANCH`, retry. Still unknown (first
///    deploy): `worktree add --detach DIR HEAD` + `checkout --orphan
///    BRANCH` inside the worktree.
/// 3. Known: `worktree add --detach DIR REMOTE/BRANCH`.
/// 4. Content sync (pure Dart I/O, deterministic): wipe everything in the
///    worktree except the `.git` entry, then copy the source directory
///    (default ignore set: `.git`).
/// 5. `add -A`, `status --porcelain` — empty status fails actionably
///    (allow-empty false as code: nothing changed → nothing to publish).
/// 6. `commit -m <message>`, `push <remote> HEAD:refs/heads/<branch>`.
/// 7. Cleanup (best effort): `worktree remove --force`, then `prune`.
class GhPagesUploadStep extends BuildStep {
  GhPagesUploadStep(this.target);

  /// The deploy target whose config this step executes.
  final GhPagesDeployTarget target;

  @override
  String get name => 'gh-pages-upload';

  @override
  Set<Artifact<Object>> get requires =>
      {Artifact<String>(target.directoryArtifactId)};

  /// Git environment for the child processes: ambient host environment
  /// plus `GIT_TERMINAL_PROMPT=0` — git must never hang waiting for
  /// interactive input; ambient credentials only.
  static Map<String, String> gitEnvironment() => {
        ...Platform.environment,
        'GIT_TERMINAL_PROMPT': '0',
      };

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    final configIssues = target.validateConfig();
    if (configIssues.isNotEmpty) {
      return StepResult.failure(
        'GhPagesDeployTarget config is invalid:\n'
        '${configIssues.map((final i) => '  - $i').join('\n')}',
      );
    }

    final artifactPath = state[target.directoryArtifactId];
    if (artifactPath is! String || artifactPath.isEmpty) {
      return StepResult.failure(
        'artifact "${target.directoryArtifactId}" is missing — the gh-pages '
        'deploy consumes the web build directory (compose after '
        '`flutter build web`, or set sourceDir in the typed config)',
      );
    }
    var sourceDir = artifactPath;
    final sub = target.subdirectory;
    if (sub != null && sub.isNotEmpty) sourceDir = p.join(artifactPath, sub);
    final source = Directory(sourceDir);
    if (!source.existsSync()) {
      return StepResult.failure(
        'source directory "$sourceDir" does not exist — build the web '
        'output first (`flutter build web` via the web-build target), or '
        'point sourceDir / "${target.directoryArtifactId}" at an existing '
        'directory',
      );
    }

    final worktreeDir =
        p.join(ctx.buildDir, 'gh-pages', 'worktree');
    final worktree = Directory(worktreeDir);
    if (worktree.existsSync()) worktree.deleteSync(recursive: true);
    await Directory(p.dirname(worktreeDir)).create(recursive: true);

    final env = gitEnvironment();
    Future<ProcOutcome> git(
      final List<String> args, {
      required final String cwd,
    }) =>
        ctx.runner.run('git', args, workingDirectory: cwd, environment: env);

    final projectPath = ctx.projectPath;

    // 1–3: obtain a worktree on the right base commit.
    final known = await git(
      target.verifyRemoteBranchArgs(),
      cwd: projectPath,
    );
    var orphan = false;
    if (known.ok) {
      final added = await git(
        target.worktreeAddRemoteBranchArgs(worktreeDir),
        cwd: projectPath,
      );
      if (!added.ok) {
        return StepResult.failure(
          'git worktree add failed (exit ${added.exitCode}):\n'
          '${added.stderr}${added.stdout}',
        );
      }
    } else {
      final fetched = await git(
        target.fetchBranchArgs(),
        cwd: projectPath,
      );
      final knownAfterFetch = fetched.ok &&
          (await git(
            target.verifyRemoteBranchArgs(),
            cwd: projectPath,
          ))
              .ok;
      if (knownAfterFetch) {
        final added = await git(
          target.worktreeAddRemoteBranchArgs(worktreeDir),
          cwd: projectPath,
        );
        if (!added.ok) {
          return StepResult.failure(
            'git worktree add failed (exit ${added.exitCode}):\n'
            '${added.stderr}${added.stdout}',
          );
        }
      } else {
        // First deploy: the remote branch does not exist yet. Detach on
        // HEAD and create an orphan branch inside the worktree.
        orphan = true;
        final added = await git(
          target.worktreeAddHeadArgs(worktreeDir),
          cwd: projectPath,
        );
        if (!added.ok) {
          return StepResult.failure(
            'git worktree add failed (exit ${added.exitCode}):\n'
            '${added.stderr}${added.stdout}',
          );
        }
        final orphanCheckout = await git(
          target.checkoutOrphanArgs(),
          cwd: worktreeDir,
        );
        if (!orphanCheckout.ok) {
          return StepResult.failure(
            'git checkout --orphan ${target.branch} failed '
            '(exit ${orphanCheckout.exitCode}):\n'
            '${orphanCheckout.stderr}${orphanCheckout.stdout}',
          );
        }
      }
    }

    try {
      // The faked-in-tests (or real-git) worktree checkout must exist as a
      // directory before the content sync.
      await Directory(worktreeDir).create(recursive: true);
      // 4: content sync — wipe everything except `.git`, then copy the
      // source directory (default ignore set: `.git`).
      _syncDirectory(source: sourceDir, into: worktreeDir);

      // 5: stage + change detection (allow-empty false, as code).
      final add = await git(target.addAllArgs(), cwd: worktreeDir);
      if (!add.ok) {
        return StepResult.failure(
          'git add failed (exit ${add.exitCode}):\n'
          '${add.stderr}${add.stdout}',
        );
      }
      final status =
          await git(target.statusPorcelainArgs(), cwd: worktreeDir);
      if (!status.ok) {
        return StepResult.failure(
          'git status failed (exit ${status.exitCode}):\n'
          '${status.stderr}${status.stdout}',
        );
      }
      if (status.stdout.trim().isEmpty) {
        return StepResult.failure(
          'nothing to publish: the source directory is identical to the '
          'current content of ${target.remote}/${target.branch} (allow-empty '
          'commits are disabled). Rebuild the web output, or publish a '
          'different directory via sourceDir / subdirectory.',
        );
      }

      // 6: commit + push (ambient auth — never any token input).
      final commit = await git(
        target.commitArgs(),
        cwd: worktreeDir,
      );
      if (!commit.ok) {
        return StepResult.failure(
          'git commit failed (exit ${commit.exitCode}):\n'
          '${commit.stderr}${commit.stdout}',
        );
      }
      final push = await git(
        target.pushArgs(),
        cwd: worktreeDir,
      );
      if (!push.ok) {
        return StepResult.failure(
          'git push to ${target.remote}/${target.branch} failed '
          '(exit ${push.exitCode}) — ambient git credentials did not '
          'resolve; check `git push` on this host manually:\n'
          '${push.stderr}${push.stdout}',
        );
      }
    } finally {
      // 7: cleanup (best effort) — the worktree must not outlive the run.
      await git(
        target.worktreeRemoveArgs(worktreeDir),
        cwd: projectPath,
      );
      await git(target.worktreePruneArgs(), cwd: projectPath);
    }

    return StepResult.success({
      'gh-pages-branch': target.branch,
      'gh-pages-remote': target.remote,
      if (orphan) 'gh-pages-orphan': 'true',
      'artifact-path': sourceDir,
    });
  }

  /// Deterministic content sync: remove every worktree entry except the
  /// `.git` marker, then copy [source] recursively (skipping `.git`).
  static void _syncDirectory({
    required final String source,
    required final String into,
  }) {
    final root = Directory(into);
    for (final entity in root.listSync()) {
      if (p.basename(entity.path) == '.git') continue;
      entity.deleteSync(recursive: true);
    }
    _copyTree(Directory(source), into);
  }

  static void _copyTree(final Directory dir, final String targetPath) {
    for (final entity in dir.listSync()) {
      final name = p.basename(entity.path);
      if (name == '.git') continue; // default ignore set
      final destination = p.join(targetPath, name);
      if (entity is Directory) {
        Directory(destination).createSync(recursive: true);
        _copyTree(entity, destination);
      } else if (entity is File) {
        File(entity.path).copySync(destination);
      }
    }
  }
}
