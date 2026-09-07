import 'package:http/http.dart' as http;
import 'package:oka_core/oka_core.dart';

import 'agc_api.dart';
import 'agc_publish_step.dart';
import 'gms_variant.dart';
import 'huawei_release_config.dart';

export 'agc_api.dart';
export 'agc_credentials.dart';
export 'agc_publish_step.dart';
export 'gms_variant.dart';
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
/// The target composes a [HuaweiBuildVariant] — the ADR-0013 two-axis law:
/// the same Android app, built **without GMS dependencies** for
/// AppGallery, plus this publish tail. Composition-time safety is the
/// standard artifact checker: a step requiring a
/// `gmsDependencyArtifact` in a pipeline composed from the variant fails
/// validation before any tool runs (tested in this package).
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
    this.release = const HuaweiReleaseConfig(),
    this.variant = const HuaweiBuildVariant(),
    this.credentialPath,
    this.endpoints = const AgcEndpoints(),
    this.httpFactory,
    this.artifactPath,
  });

  /// Dry-run is the default: publishing targets plan unless explicitly
  /// told to execute.
  @override
  final bool dryRun;

  /// Typed release metadata (track, release notes, phase).
  final HuaweiReleaseConfig release;

  /// The GMS-excluding Android build variant this target composes.
  final HuaweiBuildVariant variant;

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

  @override
  String get name => 'publish-huawei';

  @override
  String get description =>
      'Upload the AAB to Huawei AppGallery Connect '
      '(GMS-excluded variant, track ${release.track})';

  @override
  String get endpoint => 'AppGallery Connect Publishing API '
      '(${endpoints.baseUrl})';

  @override
  String get track => release.track;

  @override
  String get artifactId => HuaweiStageAabStep.aabPath.id;

  @override
  Map<String, String> get metadata => release.planMetadata;

  @override
  List<CredentialRef> get credentialRefs => [_credentialRef(credentialPath)];

  @override
  List<BuildStep> publishSteps(final BuildContext ctx) => [
        HuaweiStageAabStep(artifactPath: artifactPath),
      ];

  @override
  BuildStep uploadStep(final BuildContext ctx) => AgcPublishStep(
        release: release,
        credentialRef: _credentialRef(credentialPath),
        endpoints: endpoints,
        httpFactory: httpFactory,
      );

  @override
  String toString() => 'HuaweiPublishTarget(${release.appId}, '
      'track ${release.track}${dryRun ? ' [dry-run]' : ''}, '
      '$variant)';
}

/// The credential reference specialized with the target's explicit path
/// (a const ref cannot carry a runtime path).
CredentialRef _credentialRef(final String? explicitPath) => CredentialRef(
      target: HuaweiPublishTarget.agconnectCredentials.target,
      kind: HuaweiPublishTarget.agconnectCredentials.kind,
      explicitPath: explicitPath,
    );
