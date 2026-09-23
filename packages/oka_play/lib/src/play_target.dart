import 'package:oka_core/oka_core.dart';

import 'play_credentials.dart';
import 'play_upload_step.dart';

/// Stages the publish artifact (`Artifact<String>('aab-path')` — the
/// publish contract, ADR-0014). Moved to `oka_core` (ADR-0023 §2: staging
/// is a shared Android delivery primitive, not a per-store copy); kept as a
/// re-export for existing imports.
export 'package:oka_core/oka_core.dart' show StageAabStep;

/// Play release track (androidpublisher/v3 track ids).
enum PlayTrack {
  /// The `internal` track — oka's default (ADR-0014 P1: AAB → internal).
  internal,

  /// The `alpha` (closed) track.
  alpha,

  /// The `beta` (open) track.
  beta,

  /// The `production` track.
  production;

  /// The androidpublisher/v3 track id (identical to the enum name).
  String get apiName => name;
}

/// The Google Play publish target (ADR-0014 P1): composes the Play
/// Publisher API upload tail onto any oka Android AAB build.
///
/// Typed, const-constructible config — declared in the project composition
/// root and run with `oka run publish-play` (ADR-0015 verb/target split; no
/// CLI changes):
///
/// ```dart
/// Oka(
///   pipelines: [AndroidPipeline(config: AndroidBuild(packageName: '...'))],
///   targets: [
///     // ONE target per project (names are unique): dry-run today —
///     // flip `dryRun: false` when the plan looks right.
///     PlayPublishTarget(
///       packageName: 'dev.example.app',
///       // dryRun: false,
///       // serviceAccountPath: 'credentials/play-sa.json', // path only!
///     ),
///   ],
/// )
/// ```
///
/// Conformance laws (ADR-0014, asserted via `oka_conformance`):
///
/// 1. **Dry-run without credentials succeeds** — [dryRun] defaults to
///    `true`; the compiled chain substitutes [PlayUploadStep] with the
///    `publish-plan` step, which describes exactly what a real run would do
///    and issues zero HTTP.
/// 2. **No interactive input (standard input), ever.**
/// 3. **No secret values in state/logs/plans** — the service-account JSON
///    is referenced by *path* ([CredentialRef]); only the path reference
///    (redacted) enters the plan.
class PlayPublishTarget extends PublishTarget {
  const PlayPublishTarget({
    this.dryRun = true,
    this.targetName = 'publish-play',
    this.packageName = '',
    this.releaseTrack = PlayTrack.internal,
    this.userFraction,
    this.releaseName = '',
    this.serviceAccountPath,
    this.serviceAccountEnvVar,
    this.artifactPath,
    this.verifier,
  });

  /// Typed dry-run flag — `true` by default (safe-by-default publishing:
  /// a real upload is an explicit decision).
  @override
  final bool dryRun;

  /// Project-declared target name. The default preserves the historical CLI
  /// name; compositions may declare several Play-compatible targets without
  /// coupling the CLI to store names.
  final String targetName;

  /// Target application package name, e.g. `dev.example.app`. Empty → the
  /// upload step fails with remediation (dry-run plans still render).
  final String packageName;

  /// Release track ([PlayTrack.internal] by default).
  final PlayTrack releaseTrack;

  /// Staged-rollout fraction (0 < x < 1). Only sent when set; the release
  /// status becomes `inProgress` instead of `completed`.
  final double? userFraction;

  /// Optional release name shown in the Play console.
  final String releaseName;

  /// Explicit service-account JSON *path* (tier 1 of the credential
  /// policy). Null → the `OKA_PLAY_SERVICE_ACCOUNT_JSON` env var and the
  /// well-known location are tried, in order. A configured-but-missing
  /// path fails without falling through.
  final String? serviceAccountPath;

  /// Overrides the credential env var name (default
  /// `OKA_PLAY_SERVICE_ACCOUNT_JSON`).
  final String? serviceAccountEnvVar;

  /// Explicit publish-artifact path override (typed config, ADR-0014).
  /// Highest precedence in [StageAabStep]: set it when the AAB lives
  /// outside oka's default output layout. Null → the staged path resolves
  /// from the pipeline state (an in-pipeline AAB build) or oka's default
  /// AAB output location.
  final String? artifactPath;

  /// Pre-upload delivery gate (ADR-0023 §3). Compose the platform
  /// verifier in the project root — for Android AAB uploads:
  ///
  /// ```dart
  /// PlayPublishTarget(verifier: AndroidDeliveryVerifier())
  /// ```
  ///
  /// When set (and [dryRun] is false), the compiled chain inserts a
  /// [DeliveryVerificationStep] between staging and the upload tail; a
  /// failed gate aborts before any HTTP.
  @override
  final DeliveryVerifier? verifier;

  /// The credential path reference (never a value).
  CredentialRef get serviceAccountRef => playServiceAccountRef(
    explicitPath: serviceAccountPath,
    envVar: serviceAccountEnvVar,
  );

  /// Target name: `publish-play`.
  @override
  String get name => targetName;

  /// Explain-text: track and dry-run posture.
  @override
  String get description =>
      'Upload the AAB to Google Play '
      '(${releaseTrack.apiName} track${dryRun ? ', dry run' : ''})';

  /// Remote endpoint summary for the deploy plan.
  @override
  String get endpoint => 'Google Play Publisher API (androidpublisher/v3)';

  /// Publish track: the release track's API name.
  @override
  String get track => releaseTrack.apiName;

  /// Consumed artifact: the staged AAB path.
  @override
  String get artifactId => 'aab-path';

  @override
  Map<String, String> get metadata => {
    if (packageName.isNotEmpty) 'packageName': packageName,
    if (releaseName.isNotEmpty) 'releaseName': releaseName,
    if (userFraction != null) 'userFraction': userFraction!.toStringAsFixed(2),
  };

  /// Credentials consumed by the upload tail: the redacting service
  /// account path reference.
  @override
  List<CredentialRef> get credentialRefs => [serviceAccountRef];

  /// Staging steps: the AAB stage with the typed path override.
  @override
  List<BuildStep> publishSteps(final BuildContext ctx) => [
    StageAabStep(artifactPath: artifactPath),
  ];

  /// The upload tail: [PlayUploadStep].
  @override
  BuildStep uploadStep(final BuildContext ctx) => PlayUploadStep(this);

  /// Typed-config validation issues (empty = valid). Pure — used by the
  /// upload step and available to tooling; a misconfigured target fails
  /// before any HTTP (e.g. `userFraction` outside (0, 1)).
  List<String> validateConfig() {
    final issues = <String>[];
    final uf = userFraction;
    if (uf != null && (uf <= 0 || uf >= 1)) {
      issues.add(
        'userFraction must be strictly between 0 and 1 (staged rollout), '
        'got $uf',
      );
    }
    if (packageName.isEmpty) {
      issues.add(
        'packageName is empty — set it in the PlayPublishTarget typed '
        'config (the upload step cannot address an application without it)',
      );
    }
    return issues;
  }

  /// Debug string: track plus dry-run marker.
  @override
  String toString() =>
      'PlayPublishTarget(${releaseTrack.apiName}${dryRun ? ' [dry-run]' : ''})';
}
