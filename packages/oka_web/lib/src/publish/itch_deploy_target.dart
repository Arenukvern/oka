/// The `publish-itch` target (ADR-0016 W2): deploy a **directory** artifact
/// to itch.io via `butler push <dir> <user>/<game>:<channel>`.
///
/// Auth model: butler's own credential store plus an optional API key
/// surfaced **only** as a [CredentialRef] (`BUTLER_API_KEY` env var or the
/// well-known file). The step may pass the key to the child process via
/// its environment — the value is never logged, echoed, or stored: no
/// secret value ever enters [PipelineState], step data, or events.
///
/// Composition (ADR-0016 §2): identical to `GhPagesDeployTarget` — the
/// target consumes the directory artifact of an oka web build chain
/// (`web-build-output` → `build/web` by default) and is independently
/// composable (point [sourceDir] at any directory, e.g. a packaged zip
/// directory for HTML5 games).
///
/// Why [dryRun] defaults to `true`: a real `butler push` is a destructive
/// remote publish; it must always be an explicit decision (flip
/// `dryRun: false` in typed config).
library;

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import 'stage_web_dir_step.dart';

/// The `publish-itch` [PublishTarget].
@immutable
class ItchDeployTarget extends PublishTarget {
  const ItchDeployTarget({
    required this.user,
    required this.game,
    this.dryRun = true,
    this.channel = 'web',
    this.directoryArtifactId = StageWebDirectoryStep.defaultDirectoryArtifactId,
    this.sourceDir,
    this.butlerBinary = 'butler',
    this.apiKeyPath,
    this.apiKeyEnvVar,
  });

  /// Typed dry-run flag — `true` by default. Deploys are destructive: the
  /// upload tail publishes to a live itch.io channel, so a real push is
  /// always an explicit, deliberate flip.
  @override
  final bool dryRun;

  /// itch.io user (account) name. Part of the butler push channel
  /// address — validated by [validateConfig].
  final String user;

  /// itch.io game (project) name. Part of the butler push channel
  /// address — validated by [validateConfig].
  final String game;

  /// itch.io channel (default `web` — browser-playable builds).
  final String channel;

  /// The directory artifact id this target consumes (default:
  /// `web-build-output`, produced by `FlutterWebBuildStep`).
  final String directoryArtifactId;

  /// Explicit source directory override (typed config). Null → the staged
  /// state artifact → `<project>/build/web`.
  final String? sourceDir;

  /// Butler executable name (default `butler`; override for a pinned
  /// toolchain path).
  final String butlerBinary;

  /// Explicit API-key **file path** (typed config, path only — the file
  /// contains the key; the key value never enters oka). Highest-precedence
  /// resolution source.
  final String? apiKeyPath;

  /// Overrides the API-key env var name (default `BUTLER_API_KEY`).
  ///
  /// Credential-model note (documented deviation): unlike the ADR-0014
  /// path-ref tier-2, this env var names a **value** (butler's own
  /// convention), not a credential file path. It is still surfaced only as
  /// a redacting [CredentialRef]; the value flows straight to the butler
  /// child-process environment and is never logged or stored.
  final String? apiKeyEnvVar;

  /// The redacting API-key reference (path/value-location only, never a
  /// value).
  CredentialRef get apiKeyRef => CredentialRef(
        target: 'itch',
        kind: 'butler-api-key',
        explicitPath: apiKeyPath,
        envVar: apiKeyEnvVar ?? 'BUTLER_API_KEY',
      );

  /// The butler push channel address: `<user>/<game>:<channel>`.
  String get channelAddress => '$user/$game:$channel';

  /// Publishes a directory artifact, not a single file.
  @override
  bool get artifactIsDirectory => true;

  /// Target name: `publish-itch`.
  @override
  String get name => 'publish-itch';

  /// Explain-text: where the build directory goes and whether it's a dry
  /// run.
  @override
  String get description =>
      'Push the web build directory to itch.io ($channelAddress via '
      'butler${dryRun ? ', dry run' : ''})';

  /// Remote endpoint summary for the deploy plan.
  @override
  String get endpoint => 'itch.io (butler push)';

  /// Publish track: the itch.io channel.
  @override
  String get track => channel;

  /// Consumed artifact: the staged web build directory.
  @override
  String get artifactId => directoryArtifactId;

  /// Publish metadata: user, game, and channel.
  @override
  Map<String, String> get metadata => {
        'user': user,
        'game': game,
        'channel': channel,
      };

  /// Credentials consumed by the upload tail: the redacting butler API
  /// key reference.
  @override
  List<CredentialRef> get credentialRefs => [apiKeyRef];

  /// Stages the consumed directory artifact from typed config or the
  /// default `build/web` location.
  @override
  List<BuildStep> publishSteps(final BuildContext ctx) => [
        StageWebDirectoryStep(
          artifactId: directoryArtifactId,
          sourceDir: sourceDir,
        ),
      ];

  /// The upload tail: [ButlerUploadStep].
  @override
  BuildStep uploadStep(final BuildContext ctx) => ButlerUploadStep(this);

  /// Typed-config validation issues (empty = valid). Pure. The push
  /// address is passed as a single argv element (oka never spawns a
  /// shell), but user/game/channel are still restricted to safe
  /// identifier characters — spaces or shell metacharacters in a store
  /// address indicate a mistyped config and fail here with actionable
  /// errors, before any tool runs.
  List<String> validateConfig() {
    final issues = <String>[];
    void check(final String what, final String value) {
      if (value.isEmpty) {
        issues.add('$what is empty — set it in the ItchDeployTarget typed '
            'config (butler cannot address a channel without it)');
      } else if (!_identifierPattern.hasMatch(value)) {
        issues.add(
          '$what "$value" is not a safe itch.io identifier — use letters, '
          'digits, dots, dashes, underscores (no spaces, no shell '
          'metacharacters, no leading dash)',
        );
      }
    }

    check('user', user);
    check('game', game);
    check('channel', channel);
    if (butlerBinary.isEmpty ||
        butlerBinary.contains(RegExp('[^A-Za-z0-9_./-]'))) {
      issues.add(
        'butlerBinary "$butlerBinary" is not a safe executable name — use a '
        'plain name or path without spaces/metacharacters, e.g. "butler"',
      );
    }
    return issues;
  }

  /// Debug string: channel address plus dry-run marker.
  @override
  String toString() => 'ItchDeployTarget($channelAddress'
      '${dryRun ? ' [dry-run]' : ''})';

  /// ADR-0016 W1: pure deploy-posture lines for `oka explain --targets` —
  /// no I/O, no plan resolution (the artifact path resolves at run time).
  @override
  List<String> explainDetails(final BuildContext ctx) {
    final artifactLine = 'artifact: $artifactId '
        '(directory — ADR-0016 directory-artifact convention)';
    final dryRunLine = dryRun
        ? 'dry run: yes — nothing is pushed; flip dryRun: false to deploy '
            'for real'
        : 'dry run: NO — a real butler push runs';
    return [
      'deploy plan: $endpoint',
      artifactLine,
      'channel: $channelAddress',
      dryRunLine,
    ];
  }
}

/// Safe itch.io identifier: letters/digits then letters, digits, `.`, `-`,
/// `_`. No spaces, no shell metacharacters, no leading dash.
final RegExp _identifierPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

/// Pure command builders for butler invocations (extension on
/// [ItchDeployTarget]).
extension ButlerCommands on ItchDeployTarget {
  /// ButlER push arguments (the executable is passed separately to the
  /// process runner): `push DIR USER/GAME:CHANNEL`.
  List<String> pushArgs({required final String directory}) =>
      ['push', directory, channelAddress];

  /// `--version` — availability probe before the real push.
  List<String> versionArgs() => ['--version'];
}

/// The real upload tail: `butler push <dir> <user>/<game>:<channel>` via
/// `ctx.runner` (no shell, no interactive input).
///
/// API-key resolution (in order, matching the [CredentialRef] policy
/// tiers): typed-config file path ([ItchDeployTarget.apiKeyPath]) →
/// `BUTLER_API_KEY` env var (the key **value**, butler's convention) →
/// well-known file `~/.oka/credentials/itch/butler-api-key`. When resolved
/// from a file, the trimmed file content is passed to the butler child
/// process via its environment (`BUTLER_API_KEY`) — the value never enters
/// [PipelineState], step data, logs, or events. When nothing resolves, the
/// step fails actionably (butler must never be left to prompt).
class ButlerUploadStep extends BuildStep {
  /// Wraps [target]; [environment] defaults to the host environment
  /// (injectable for tests).
  ButlerUploadStep(this.target, {final Map<String, String>? environment})
      : environment = environment ?? Platform.environment;

  /// The deploy target whose config this step executes.
  final ItchDeployTarget target;

  /// Host environment (injectable for tests); the butler child process
  /// inherits this plus the resolved `BUTLER_API_KEY` when the key came
  /// from a file.
  final Map<String, String> environment;

  /// Step name: `butler-push`.
  @override
  String get name => 'butler-push';

  /// Requires the staged web build directory artifact.
  @override
  Set<Artifact<Object>> get requires =>
      {Artifact<String>(target.directoryArtifactId)};

  /// Validates config, resolves the directory artifact and API key, then
  /// runs `butler push` via [BuildContext.runner] (no shell, no
  /// interactive input). Fails actionably on missing config/artifact/key
  /// or non-zero butler exit.
  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    final configIssues = target.validateConfig();
    if (configIssues.isNotEmpty) {
      return StepResult.failure(
        'ItchDeployTarget config is invalid:\n'
        '${configIssues.map((final i) => '  - $i').join('\n')}',
      );
    }

    final dirPath = state[target.directoryArtifactId];
    if (dirPath is! String || dirPath.isEmpty) {
      return StepResult.failure(
        'artifact "${target.directoryArtifactId}" is missing — the itch '
        'deploy consumes the web build directory (compose after '
        '`flutter build web`, or set sourceDir in the typed config)',
      );
    }
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      return StepResult.failure(
        'directory "$dirPath" does not exist — build the web output first '
        '(`flutter build web` via the web-build target), or point '
        'sourceDir / "${target.directoryArtifactId}" at an existing '
        'directory',
      );
    }

    // Credential resolution — the value stays in this local scope and is
    // handed to the child process environment only. Never logged/stored.
    final apiKey = _resolveApiKey();
    if (apiKey == null) {
      return StepResult.failure(
        'no butler API key resolved — tried (in order): the typed-config '
        'path (${target.apiKeyRef.explicitPath ?? 'not set'}), the env var '
        '${target.apiKeyRef.envVarName}, and the well-known location '
        '${target.apiKeyRef.wellKnownPath}. Put the key in one of those '
        'sources (paths/env only — oka never stores key values); or log '
        'in once with `butler login` so butler uses its own store.',
      );
    }

    final childEnvironment = {
      ...environment,
      target.apiKeyRef.envVarName: apiKey,
    };

    final result = await ctx.runner.run(
      target.butlerBinary,
      target.pushArgs(directory: dirPath),
      workingDirectory: ctx.projectPath,
      environment: childEnvironment,
    );
    if (!result.ok) {
      return StepResult.failure(
        'butler push failed (exit ${result.exitCode}) — butler diagnostics '
        'follow verbatim (the API key was passed via the child-process '
        'environment, never as an argument, and is never stored in oka '
        'state):\n'
        '${result.stderr}${result.stdout}',
      );
    }

    return StepResult.success({
      'itch-channel': target.channelAddress,
      'artifact-path': dirPath,
    });
  }

  /// Ordered API-key resolution: typed-config path → env var → well-known
  /// file. Returns the raw value (caller keeps it in local scope) or null.
  String? _resolveApiKey() {
    final explicitPath = target.apiKeyPath;
    if (explicitPath != null && explicitPath.isNotEmpty) {
      final file = File(explicitPath);
      if (!file.existsSync()) return null; // configured-but-missing: no
      // fall-through (ADR-0014 credential policy, tier 1).
      return file.readAsStringSync().trim();
    }
    final envValue = environment[target.apiKeyRef.envVarName];
    if (envValue != null && envValue.isNotEmpty) return envValue;
    final home = environment['HOME'];
    if (home != null && home.isNotEmpty) {
      final wellKnown = File(p.join(
        home,
        '.oka',
        'credentials',
        'itch',
        target.apiKeyRef.wellKnownFileNameOrDefault,
      ));
      if (wellKnown.existsSync()) return wellKnown.readAsStringSync().trim();
    }
    return null;
  }
}
