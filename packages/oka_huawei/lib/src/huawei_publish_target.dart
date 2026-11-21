import 'package:http/http.dart' as http;
import 'package:oka_core/oka_core.dart';

import 'agc_api.dart';
import 'agc_publish_step.dart';
import 'huawei_distribution_policy.dart';
import 'huawei_release_config.dart';

// `gms_variant.dart` stays exported for legacy compositions; the target
// itself no longer composes a build variant (ADR-0055 — channels publish,
// deliveries build).

export 'agc_api.dart';
export 'agc_credentials.dart';
export 'agc_publish_step.dart';
export 'gms_variant.dart';
export 'huawei_distribution_policy.dart';
export 'huawei_release_config.dart';

/// The Huawei AppGallery Connect distribution target (ADR-0014 P2).
///
/// A [PublishTarget] per the P0 contract: typed, compiles to a validated
/// pipeline, and carries the three publishing laws as code —
///
/// 1. **Dry-run without credentials succeeds.** With [dryRun] (the
///    default), the compiled chain is `huawei-stage-aab` →
///    `publish-plan`: the plan names the endpoint
///    ([AgcEndpoints.defaultBaseUrl]), the track, the artifact, and the
///    release metadata, and issues **no HTTP**.
/// 2. **No interactive input, ever.**
/// 3. **No secret values in state** — only the redacting
///    [CredentialRef] `huawei/agconnect-credentials` enters plans/state;
///    the AGC token and API-client secret live in the upload step's local
///    scope.
///
/// The target is a **channel only** (ADR-0055): it consumes the artifact
/// a delivery's pipeline produced — the GMS-free posture is the
/// DELIVERY's job (`hms-free` overlay excludes the Google SDK groups;
/// this channel prohibits the `gms` overlay at composition time). The
/// opt-in [verifyArtifact] filesystem gate derives its exclusion set
/// from the delivery context's overlays, so one source of truth carries
/// the GMS-free boundary from composition through verification.
///
/// ```dart
/// const target = HuaweiPublishTarget(
///   dryRun: true,
///   release: HuaweiReleaseConfig(appId: '110012345'),
/// );
/// final chain = describeTarget(target, ctx); // validated, never executed
/// ```
class HuaweiPublishTarget extends PublishTarget {
  const HuaweiPublishTarget({
    this.dryRun = true,
    this.targetName = 'publish-huawei',
    this.release = const HuaweiReleaseConfig(),
    this.policy = const HuaweiDistributionPolicy(),
    this.verifyArtifact = false,
    this.credentialPath,
    this.endpoints = const AgcEndpoints(),
    this.httpFactory,
    this.artifactPath,
  });

  /// Dry-run is the default: publishing targets plan unless explicitly
  /// told to execute.
  @override
  final bool dryRun;

  /// Project-declared target name. Defaults to the legacy name for backwards
  /// compatibility; the CLI treats it as an opaque target identifier.
  final String targetName;

  /// Typed release metadata (track, release notes, phase).
  final HuaweiReleaseConfig release;

  /// Store-owned artifact and dependency gates.
  final HuaweiDistributionPolicy policy;

  /// Opt into the filesystem AAB gate for non-dry runs. Kept opt-in so
  /// existing upload compositions retain their historical step contract.
  final bool verifyArtifact;

  /// Explicit credential path (highest-precedence policy source); null →
  /// env var / well-known location per the P0 [CredentialResolver] policy.
  final String? credentialPath;

  /// AGC endpoints (tests point these at the fake transport).
  final AgcEndpoints endpoints;

  /// HTTP transport factory (tests inject a fake; production defaults to a
  /// real [http.Client] inside the upload step).
  final http.Client Function()? httpFactory;

  /// Explicit publish-artifact path override (typed config, ADR-0014).
  /// Highest precedence in [HuaweiStageAabStep]; null → the staged path
  /// resolves from the pipeline state or oka's default AAB output layout.
  final String? artifactPath;

  /// The redacting credential reference (path only, never values).
  static const agconnectCredentials = CredentialRef(
    target: 'huawei',
    kind: 'agconnect-credentials',
  );

  /// Target name: `publish-huawei`.
  @override
  String get name => targetName;

  /// Explain-text: the GMS-free channel posture and track.
  @override
  String get description =>
      'Upload the AAB to Huawei AppGallery Connect '
      "(GMS-free posture — the delivery's overlays carry the exclusion "
      'set; this channel prohibits the gms overlay, '
      'track ${release.track})';

  /// Remote endpoint summary for the deploy plan.
  @override
  String get endpoint =>
      'AppGallery Connect Publishing API '
      '(${endpoints.baseUrl})';

  /// Publish track: the release config's track.
  @override
  String get track => release.track;

  /// Consumed artifact: the staged AAB path.
  @override
  String get artifactId => HuaweiStageAabStep.aabPath.id;

  /// ADR-0055 capability + law: AppGallery accepts Android AABs built
  /// WITHOUT GMS — the composition-time face of the ADR-0013 GMS
  /// exclusion (the `gms` overlay is prohibited by the channel).
  @override
  Set<String> get acceptedPlatforms => const {'android'};

  @override
  Set<String> get acceptedArtifactFormats => const {'aab'};

  @override
  Set<String> get prohibitedOverlays => const {'gms'};

  /// Publish metadata from the release config (non-secret).
  @override
  Map<String, String> get metadata => release.planMetadata;

  /// Credentials consumed by the upload tail: the redacting AGC
  /// credentials path reference.
  @override
  List<CredentialRef> get credentialRefs => [_credentialRef(credentialPath)];

  /// Staging steps: the Huawei AAB stage with the typed path override.
  /// The opt-in verification gate reads its exclusion set from the
  /// delivery context's overlays (ADR-0055 — the delivery owns the
  /// GMS-free posture; the channel verifies the produced artifact
  /// against the same declaration).
  @override
  List<BuildStep> publishSteps(BuildContext ctx) => [
    HuaweiStageAabStep(artifactPath: artifactPath),
    if (!dryRun && verifyArtifact)
      HuaweiArtifactVerificationStep(
        policy: policy,
        dependencies: [
          for (final overlay in ctx.overlays)
            ...overlay.excludesFor('android'),
        ],
      ),
  ];

  /// The upload tail: [AgcPublishStep] with the release config and
  /// credential reference.
  @override
  BuildStep uploadStep(BuildContext ctx) => AgcPublishStep(
    release: release,
    credentialRef: _credentialRef(credentialPath),
    endpoints: endpoints,
    httpFactory: httpFactory,
  );

  /// Debug string: app id, track, dry-run marker.
  @override
  String toString() =>
      'HuaweiPublishTarget(${release.appId}, '
      'track ${release.track}${dryRun ? ' [dry-run]' : ''})';
}

/// The credential reference specialized with the target's explicit path
/// (a const ref cannot carry a runtime path).
CredentialRef _credentialRef(String? explicitPath) => CredentialRef(
  target: HuaweiPublishTarget.agconnectCredentials.target,
  kind: HuaweiPublishTarget.agconnectCredentials.kind,
  explicitPath: explicitPath,
);
