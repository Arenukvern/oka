import 'package:meta/meta.dart';

import '../config/build_context.dart';
import '../credentials/credential_ref.dart';
import '../pipeline/pipeline.dart';
import '../targets/target.dart';

/// The dry-run publish plan: **exactly what a real run would do** — the
/// ADR-0008 plan law applied to publishing (ADR-0014).
///
/// A plan is produced by [PublishPlanStep] in dry-run mode, *without
/// credentials present and without executing any upload*. It holds no
/// secret values: endpoints, tracks, artifact ids/paths, non-secret
/// metadata, and [CredentialRef]s (redacting [toString]).
@immutable
class PublishPlan {
  const PublishPlan({
    required this.target,
    required this.endpoint,
    required this.track,
    required this.artifactId,
    required this.artifactPath,
    required this.dryRun,
    this.artifactIsDirectory = false,
    this.metadata = const {},
    this.credentials = const [],
  });

  /// Decodes from the plan payload (also what [PublishPlanStep] stores).
  factory PublishPlan.fromJson(final Map<String, dynamic> json) => PublishPlan(
        target: json['target']?.toString() ?? '',
        endpoint: json['endpoint']?.toString() ?? '',
        track: json['track']?.toString() ?? '',
        artifactId: json['artifactId']?.toString() ?? '',
        artifactPath: json['artifactPath']?.toString() ?? '',
        metadata: (json['metadata'] as Map<dynamic, dynamic>? ?? const {})
            .map((final k, final v) => MapEntry(k.toString(), v.toString())),
        credentials: [
          for (final c in (json['credentials'] as List<dynamic>? ?? const []))
            CredentialRef(
              target: (c as Map<dynamic, dynamic>)['target']?.toString() ?? '',
              kind: c['kind']?.toString() ?? '',
              explicitPath: c['explicitPath']?.toString(),
              envVar: c['envVar']?.toString(),
              wellKnownFileName: c['wellKnownFileName']?.toString(),
            ),
        ],
        dryRun: json['dryRun']?.toString() == 'true',
        artifactIsDirectory: json['artifactIsDirectory']?.toString() == 'true',
      );

  /// Target name ([Target.name]).
  final String target;

  /// Upload endpoint description, e.g. `'Google Play Publisher API'`.
  final String endpoint;

  /// Release track, e.g. `'internal'`.
  final String track;

  /// Artifact id the real upload consumes, e.g. `'aab-path'`.
  final String artifactId;

  /// Resolved artifact path at plan time.
  final String artifactPath;

  /// Non-secret metadata the real upload would send.
  final Map<String, String> metadata;

  /// Credential path references (never values).
  final List<CredentialRef> credentials;

  /// Whether this plan describes a dry run.
  final bool dryRun;

  /// Whether [artifactPath] refers to a **directory** rather than a single
  /// file — the directory-artifact convention (ADR-0016 §2): web deploy
  /// targets reference a directory path (e.g. `build/web`) as the publish
  /// artifact; file targets (AAB uploads, zips) leave this false.
  final bool artifactIsDirectory;

  /// Human/agent-readable description of exactly what a real run would do.
  List<String> describeLines() {
    final artifactKind = artifactIsDirectory ? ' (directory)' : '';
    return [
      'target: $target${dryRun ? ' (dry run — nothing was uploaded)' : ''}',
      'endpoint: $endpoint',
      'track: $track',
      'artifact: $artifactId → $artifactPath$artifactKind',
      for (final e in metadata.entries) 'metadata.${e.key}: ${e.value}',
      for (final c in credentials) 'credential: $c',
    ];
  }

  /// Encodes to the plan payload.
  Map<String, dynamic> toJson() => {
        'target': target,
        'endpoint': endpoint,
        'track': track,
        'artifactId': artifactId,
        'artifactPath': artifactPath,
        if (artifactIsDirectory) 'artifactIsDirectory': true,
        'metadata': metadata,
        'credentials': [
          for (final c in credentials)
            {
              'target': c.target,
              'kind': c.kind,
              'explicitPath': ?c.explicitPath,
              'envVar': ?c.envVar,
              'wellKnownFileName': ?c.wellKnownFileName,
            },
        ],
        'dryRun': dryRun,
      };

  @override
  bool operator ==(final Object other) =>
      other is PublishPlan &&
      other.target == target &&
      other.endpoint == endpoint &&
      other.track == track &&
      other.artifactId == artifactId &&
      other.artifactPath == artifactPath &&
      other.artifactIsDirectory == artifactIsDirectory &&
      other.dryRun == dryRun &&
      _mapsEqual(other.metadata, metadata) &&
      _listsEqual(other.credentials, credentials);

  /// Hash over all plan fields (equality is field-wise).
  @override
  int get hashCode => Object.hash(
        target,
        endpoint,
        track,
        artifactId,
        artifactPath,
        artifactIsDirectory,
        dryRun,
        Object.hashAll(metadata.keys),
        Object.hashAll(credentials),
      );

  /// Debug string: target → endpoint, track, dry-run marker.
  @override
  String toString() => 'PublishPlan($target → $endpoint, track $track, '
      'artifact $artifactId'
      '${artifactIsDirectory ? ' (directory)' : ''}'
      '${dryRun ? ', dry run' : ''})';
}

bool _mapsEqual(final Map<String, String> a, final Map<String, String> b) =>
    a.length == b.length &&
    a.entries.every((final e) => b[e.key] == e.value);

bool _listsEqual(final List<CredentialRef> a, final List<CredentialRef> b) =>
    a.length == b.length && a.indexed.every((final e) => b[e.$1] == e.$2);

/// The plan-producing tail step oka_core substitutes for the upload step in
/// dry-run mode (ADR-0014 dry-run law, as code).
///
/// Pure: no I/O, no credential file is read, nothing is uploaded. It
/// *requires* the publish artifact id, so a dry-run chain still validates
/// the full artifact path — the plan proves the real run would have
/// something to upload.
class PublishPlanStep extends BuildStep {
  /// Wraps [target].
  PublishPlanStep(this.target);

  /// The plan artifact, consumable by tooling and `oka explain`.
  static const plan = Artifact<PublishPlan>('publish-plan');

  /// The [PublishTarget] whose plan this step produces.
  final PublishTarget target;

  /// Step name: `publish-plan`.
  @override
  String get name => 'publish-plan';

  /// Requires the artifact the plan describes.
  @override
  Set<Artifact<Object>> get requires => {Artifact<String>(target.artifactId)};

  /// Provides the plan artifact.
  @override
  Set<Artifact<Object>> get provides => {plan};

  /// Resolves the artifact path from state and produces [target]'s plan;
  /// fails actionably when the artifact is missing.
  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    final artifact = state[target.artifactId];
    if (artifact is! String || artifact.isEmpty) {
      return StepResult.failure(
        'artifact "${target.artifactId}" is missing or not a path — the '
        'publish plan cannot be produced',
      );
    }
    final value = target.plan(ctx, artifactPath: artifact);
    state[plan.id] = value;
    return StepResult.success({
      'publish-plan': value.describeLines().join('\n'),
    });
  }
}

/// A [Target] with publishing conformance laws as code (ADR-0014).
///
/// A publish target is typed, const-constructible, and compiles to a
/// validated pipeline like any [Target] — plus the three publishing laws:
///
/// 1. **Dry-run without credentials must succeed.** [dryRun] is part of the
///    contract; when true, [compile] substitutes the upload step with a
///    [PublishPlanStep] that describes exactly what a real run would do
///    (endpoint / track / artifact / metadata) and executes nothing.
/// 2. **No stdin, ever** (ADR-0013 law, inherited).
/// 3. **No secret values in state, logs, or events** — only
///    [CredentialRef]s (path references) and booleans. State can be dumped
///    by tooling; treat it as public.
///
/// Target packages (`[P1]` `oka_play`, `[P2]` `oka_huawei`) extend this class
/// and assert the laws via `expectPublishConformance` — a shared suite any
/// target must pass, mirroring the `universal_storage_conformance` pattern.
abstract class PublishTarget extends Target {
  /// Const constructor for const target values.
  const PublishTarget();

  /// Typed dry-run flag — part of the publishing contract. When true, the
  /// compiled chain must succeed **without credentials present** and
  /// without executing any upload.
  bool get dryRun => false;

  /// Upload endpoint description for the plan, e.g.
  /// `'Google Play Publisher API'`.
  String get endpoint;

  /// Release track for the plan, e.g. `'internal'`.
  String get track;

  /// Artifact id the upload consumes, e.g. `'aab-path'`. Must be provided
  /// by [publishSteps] so the dry-run chain validates the artifact path.
  String get artifactId;

  /// Whether [artifactId] references a **directory** rather than a single
  /// file — the directory-artifact convention (ADR-0016 §2).
  ///
  /// Convention: web/static-site deploy targets (GitHub Pages, itch.io
  /// via butler, generic store zips over `WebZipStep`) reference a
  /// directory path (`build/web`) as the publish artifact; file targets
  /// (AAB uploads, zip files) are unchanged and keep this `false` (the
  /// default). The conformance suite (`auditPublishConformance`) asserts
  /// the declared kind when the artifact path exists on disk: a
  /// directory-artifact target must never point at a file.
  bool get artifactIsDirectory => false;

  /// Non-secret upload metadata (version, release notes reference, …).
  Map<String, String> get metadata => const {};

  /// Credential path references. Never values — a [CredentialRef] holds
  /// paths only and redacts in [CredentialRef.toString].
  List<CredentialRef> get credentialRefs => const [];

  /// Steps that produce/transform the publish artifact. Run before the
  /// upload tail; the last one must provide [artifactId].
  List<BuildStep> publishSteps(final BuildContext ctx) => const [];

  /// The real upload tail step. Never invoked when [dryRun] is true —
  /// [compile] substitutes [PublishPlanStep] instead (law 1, as code).
  BuildStep uploadStep(final BuildContext ctx);

  /// The publish plan for a real (or, with [dryRun], the described) run.
  /// Pure: a function of the target value + inputs only.
  PublishPlan plan(
    final BuildContext ctx, {
    required final String artifactPath,
  }) =>
      PublishPlan(
        target: name,
        endpoint: endpoint,
        track: track,
        artifactId: artifactId,
        artifactPath: artifactPath,
        metadata: Map.unmodifiable(metadata),
        credentials: List.unmodifiable(credentialRefs),
        dryRun: dryRun,
        artifactIsDirectory: artifactIsDirectory,
      );

  /// Compile to the publish contract: staging steps, then the plan step
  /// (dry run) or the real upload tail.
  @override
  List<BuildStep> compile(final BuildContext ctx) => [
        ...publishSteps(ctx),
        if (dryRun) PublishPlanStep(this) else uploadStep(ctx),
      ];

  /// Debug string: target name plus dry-run marker.
  @override
  String toString() => 'PublishTarget($name${dryRun ? ' [dry-run]' : ''})';
}
