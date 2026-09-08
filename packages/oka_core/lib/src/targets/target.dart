import 'package:meta/meta.dart';

import '../config/build_context.dart';
import '../pipeline/pipeline.dart';

/// Core CLI verbs, reserved across all projects (ADR-0015).
///
/// Verbs are the static, stable, agent-contract surface of oka; targets are
/// project-declared and discovered. A [Target] cannot shadow a verb — the
/// dispatcher resolves verbs first, and [validateTargetName] rejects
/// reserved names at composition time so a colliding target never ships.
///
/// `cache` is reserved ahead of its implementation (T0) so no target can
/// take the name in the meantime.
const Set<String> reservedCliVerbs = {
  'init',
  'build',
  'dev',
  'doctor',
  'clean',
  'get',
  'explain',
  'compare',
  'debug',
  'launch',
  'run',
  'cache',
};

final RegExp _targetNamePattern = RegExp(r'^[a-z][a-z0-9_-]*$');

/// Validates a target name (ADR-0015).
///
/// A valid target name is a lowercase identifier (`[a-z][a-z0-9_-]*`) that
/// does not shadow a [reservedCliVerbs] core verb. Returns an actionable
/// error message, or null when the name is valid.
String? validateTargetName(
  final String name, {
  final Set<String> reserved = reservedCliVerbs,
}) {
  if (!_targetNamePattern.hasMatch(name)) {
    return 'invalid target name "$name": targets are lowercase identifiers '
        '([a-z][a-z0-9_-]*), e.g. "device", "publish-play".';
  }
  if (reserved.contains(name)) {
    final sorted = reserved.toList()..sort();
    return 'target name "$name" shadows a reserved core verb. Core verbs are '
        'reserved and cannot be shadowed by targets (ADR-0015). '
        'Reserved verbs: ${sorted.join(', ')}. Pick another target name.';
  }
  return null;
}

/// A project-declared, platform-owned build target (ADR-0015).
///
/// Targets are the second CLI axis: static core verbs (`build`, `explain`,
/// ...) belong to oka; targets (`device`, `publish-play`, custom flows)
/// belong to the project composition root and to target packages
/// (`oka_android` ships the device target, `oka_play`/`oka_huawei` the
/// store targets). The core CLI never grows for a new platform or store.
///
/// Design law (ADR-0015): targets are **typed values**, not arbitrary
/// `(List<String>) -> Future` functions. A target *compiles* to an ordered
/// step list that goes through the same composition-time artifact
/// validation as builds ([Pipeline.validate]) — before any tool runs. This
/// is what keeps `oka explain`, plan validation, and the
/// no-execution-before-plan law intact.
///
/// A minimal custom target:
///
/// ```dart
/// class PublishPlayTarget extends Target {
///   const PublishPlayTarget();
///
///   @override
///   String get name => 'publish-play';
///
///   @override
///   String get description => 'Sign + upload the AAB to Google Play';
///
///   @override
///   List<BuildStep> compile(BuildContext ctx) => [
///         StageAabStep(),
///         UploadStep(credentials: ...),
///       ];
/// }
/// ```
///
/// Declare it in the composition root:
///
/// ```dart
/// Oka(pipelines: [...], targets: [PublishPlayTarget()])
/// ```
///
/// and run it with `oka run publish-play` (or the bare `oka publish-play` —
/// unknown verbs dispatch to targets).
@immutable
abstract class Target {
  const Target();

  /// Lowercase identifier used in `oka run <target>`. Validated by
  /// [validateTargetName] — must not shadow a reserved core verb.
  String get name;

  /// One-line description, shown when listing discovered targets.
  String get description;

  /// Optional typed config, deep-merged **over** `oka.yaml` when this target
  /// runs (same precedence as `PlatformPipeline.configOverrides`). Pure —
  /// must not read the filesystem or environment.
  Map<String, dynamic> get configOverrides => const {};

  /// Compiles this target into an ordered step list.
  ///
  /// A pure function of the target value + [ctx] — no tool invocations, no
  /// I/O. The runner wraps the result in a [Pipeline] and validates the
  /// artifact chain before executing anything.
  List<BuildStep> compile(final BuildContext ctx);

  /// Generic, platform-agnostic explain hook (ADR-0016 W1): extra pure
  /// detail lines `oka explain --targets` prints for this target, in
  /// addition to the compiled step chain (composition render, deploy
  /// plan posture, …).
  ///
  /// Pure — a function of the target value + [ctx]: no I/O, no tool
  /// invocation, no execution of compiled steps (details must come from
  /// composition, never execution). Default: no details. The CLI prints
  /// these lines verbatim without knowing what platform or store a target
  /// serves — the verb never learns platforms (ADR-0015).
  List<String> explainDetails(final BuildContext ctx) => const [];

  /// Invocation-arg keys this target accepts via `oka run <target>`
  /// --oka-target-arg key=value` (and verb shims that forward, e.g.
  /// `oka launch -d <id>` → `device=<id>`). Empty by default — a target
  /// that accepts nothing needs no override.
  Set<String> get supportedInvocationArgs => const {};

  /// Returns a NEW target value with [args] applied (targets are const
  /// values — never mutate; implementations return a copy). Called by the
  /// dispatcher before [compile] only when invocation args are present; the
  /// default rejects everything with an actionable error listing the
  /// accepted keys, so a target that accepts nothing needs no override.
  Target applyInvocationArgs(final Map<String, String> args) {
    throw ArgumentError(
      'target "$name" accepts no invocation args — got: '
      '${args.keys.join(', ')}.',
    );
  }

  @override
  String toString() => 'Target($name)';
}

/// Thrown when target resolution fails (unknown name, name shadowing a
/// reserved verb, invalid or duplicate name). Carries an actionable,
/// user-facing message — catch it to print the message without a trace.
class TargetResolutionException implements Exception {
  const TargetResolutionException(this.message);

  final String message;

  @override
  String toString() => message;
}
