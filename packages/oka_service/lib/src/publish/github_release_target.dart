import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// Stages a file artifact from an explicit path (the service-side
/// counterpart of `oka_core`'s [StageAabStep]).
///
/// Precedence: an explicit upstream with the same artifact id wins; the
/// typed [path] (project-relative or absolute) is the fallback. The
/// existence check stays downstream (dry-run must succeed without the
/// artifact — the plan describes what a real run would upload).
class StageFileStep extends BuildStep {
  StageFileStep({required this.artifactId, this.path});

  /// The artifact id to provide.
  final String artifactId;

  /// Project-relative (or absolute) file path override.
  final String? path;

  @override
  String get name => 'stage-file:$artifactId';

  @override
  Set<Artifact<Object>> get provides => {Artifact<String>(artifactId)};

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) {
    final existing = state[artifactId];
    if (existing is String && existing.isNotEmpty) {
      return Future<StepResult>.value(StepResult.success());
    }
    final raw = path ?? '';
    if (raw.isNotEmpty) {
      final resolved = p.isAbsolute(raw) ? raw : p.join(ctx.projectPath, raw);
      state[artifactId] = resolved;
    }
    return Future<StepResult>.value(StepResult.success());
  }
}

/// The GitHub Releases publish channel (ADR-0055): upload a release
/// asset with the `gh` CLI — ambient host auth only (whatever `gh` has
/// on the machine), no token inputs, no stdin.
///
/// ```dart
/// Delivery(
///   name: 'cli-release',
///   pipeline: CommandPipeline(
///     platform: 'cli',
///     commands: [CommandSpec('dart', ['compile', 'exe', 'bin/cli.dart'])],
///     artifactId: 'cli-binary',
///     artifactPath: 'build/cli',
///   ),
///   channel: GitHubReleasePublishTarget(
///     repository: 'owner/cli',
///     tag: 'v1.2.3',
///     assetPath: 'build/cli',
///   ),
/// )
/// ```
///
/// The laws (ADR-0014): dry-run (default true) plans and never uploads;
/// no stdin (`GH_TOKEN`/ambient `gh` auth only); no secret values in
/// state — a release upload has none beyond the ambient auth.
class GitHubReleasePublishTarget extends PublishTarget {
  const GitHubReleasePublishTarget({
    required this.repository,
    required this.tag,
    this.targetName = 'publish-github-release',
    this.dryRun = true,
    this.assetId = 'release-asset',
    this.assetPath,
    this.clobber = true,
  });

  /// `owner/repo` the release lives in.
  final String repository;

  /// Release tag, e.g. `v1.2.3`.
  final String tag;

  /// Project-declared target name.
  final String targetName;

  /// Typed dry-run flag — true by default (safe-by-default publishing).
  @override
  final bool dryRun;

  /// The artifact id consumed (provided by a build pipeline or staged
  /// from [assetPath]).
  final String assetId;

  /// Explicit asset path override (project-relative or absolute).
  final String? assetPath;

  /// Replace an existing asset of the same name (`--clobber`, default
  /// true — re-publishing a fixed artifact is the normal loop).
  final bool clobber;

  @override
  String get name => targetName;

  @override
  String get description =>
      'Upload the release asset to GitHub Releases '
      '($repository@$tag${dryRun ? ', dry run' : ''})';

  @override
  String get endpoint => 'GitHub Releases (gh CLI)';

  @override
  String get track => tag;

  @override
  String get artifactId => assetId;

  @override
  Map<String, String> get metadata => {
    'repository': repository,
    'tag': tag,
    if (clobber) 'clobber': 'true',
  };

  @override
  List<BuildStep> publishSteps(BuildContext ctx) => [
    StageFileStep(artifactId: assetId, path: assetPath),
  ];

  @override
  BuildStep uploadStep(BuildContext ctx) => GhReleaseUploadStep(this);

  /// Typed-config validation issues (empty = valid). Pure — the gh CLI
  /// receives every value as separate argv (no shell), but a mistyped
  /// config should fail at composition time.
  List<String> validateConfig() {
    final issues = <String>[];
    if (!RegExp(r'^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$').hasMatch(repository)) {
      issues.add(
        'repository "$repository" must be "owner/repo" '
        '(letters, digits, dots, dashes, underscores).',
      );
    }
    if (tag.isEmpty) {
      issues.add('tag is empty — a release needs a tag, e.g. "v1.2.3".');
    } else if (tag.contains(RegExp(r'\s'))) {
      issues.add('tag "$tag" must not contain whitespace.');
    }
    return issues;
  }

  /// Debug string: repo@tag plus dry-run marker.
  @override
  String toString() =>
      'GitHubReleasePublishTarget($repository@$tag${dryRun ? ' [dry-run]' : ''})';
}

/// The real upload tail: `gh release upload TAG ASSET --repo OWNER/REPO`
/// (ambient `gh` auth; gh never prompts when unauthenticated — it
/// fails).
class GhReleaseUploadStep extends BuildStep {
  GhReleaseUploadStep(this.target);

  /// The target whose config this step executes.
  final GitHubReleasePublishTarget target;

  @override
  String get name => 'gh-release-upload';

  @override
  Set<Artifact<Object>> get requires => {Artifact<String>(target.assetId)};

  /// The resolved `gh` argument vector (pure — tested directly).
  List<String> uploadArgs(BuildContext ctx, String assetPath) => [
    'release',
    'upload',
    target.tag,
    assetPath,
    '--repo',
    target.repository,
    if (target.clobber) '--clobber',
  ];

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    final issues = target.validateConfig();
    if (issues.isNotEmpty) {
      return StepResult.failure(
        'GitHubReleasePublishTarget config is invalid:\n'
        '${issues.map((i) => '  - $i').join('\n')}',
      );
    }
    final asset = state[target.assetId];
    if (asset is! String || asset.isEmpty) {
      return StepResult.failure(
        'artifact "${target.assetId}" is missing — the release upload '
        "consumes a built file (compose the delivery pipeline's "
        'artifactId, or set assetPath)',
      );
    }
    if (!File(asset).existsSync()) {
      return StepResult.failure(
        'asset "$asset" does not exist — build the artifact first or fix '
        'assetPath',
      );
    }
    final result = await ctx.runner.run(
      'gh',
      uploadArgs(ctx, asset),
      workingDirectory: ctx.projectPath,
    );
    if (!result.ok) {
      return StepResult.failure(
        'gh release upload failed (exit ${result.exitCode}) — ambient gh '
        'auth did not resolve or the release is missing; check '
        '`gh auth status` and that release ${target.tag} exists:\n'
        '${result.stderr}\n${result.stdout}',
      );
    }
    return StepResult.success({
      'gh-release': '${target.repository}@${target.tag}',
      'asset-path': asset,
    });
  }
}
