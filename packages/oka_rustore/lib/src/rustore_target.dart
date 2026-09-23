import 'package:oka_core/oka_core.dart';

import 'rustore_policy.dart';

/// RuStore target (ADR-0023): composes the shared AAB staging contract
/// (`oka_core` [StageAabStep]) with a typed readiness policy and a publish
/// tail. Publishing remains dry-run until a project supplies its
/// credential/upload adapter; a real run without one is refused at
/// composition/plan time ([validateRealMode]), before tools run.
class RuStorePublishTarget extends PublishTarget {
  const RuStorePublishTarget({
    required this.packageName,
    this.targetName = 'publish-rustore',
    this.dryRun = true,
    this.versionCode,
    this.versionName = '',
    this.artifactPath,
    this.policy,
    this.verifier,
  });

  final String targetName;
  final String packageName;
  final int? versionCode;
  final String versionName;
  final String? artifactPath;
  final RuStoreDistributionPolicy? policy;

  /// Pre-upload delivery gate (ADR-0023 §3), composed by the project root —
  /// for Android AAB uploads: `RuStorePublishTarget(
  /// verifier: AndroidDeliveryVerifier())`.
  @override
  final DeliveryVerifier? verifier;

  @override
  final bool dryRun;

  RuStoreDistributionPolicy get effectivePolicy =>
      policy ?? RuStoreDistributionPolicy(packageName: packageName);

  @override
  String get name => targetName;
  @override
  String get description =>
      'Upload an AAB to RuStore${dryRun ? ' (dry run)' : ''}';
  @override
  String get endpoint => 'RuStore publishing API';
  @override
  String get track => 'production';
  @override
  String get artifactId => StageAabStep.aab.id;
  @override
  Map<String, String> get metadata => {
    'packageName': packageName,
    if (versionCode != null) 'versionCode': '$versionCode',
    if (versionName.isNotEmpty) 'versionName': versionName,
  };

  /// Real (non-dry-run) refusals, checked at composition/plan time
  /// (ADR-0023: fail before tools run):
  ///
  /// * no project-provided credential/upload adapter exists yet — oka ships
  ///   readiness planning and verification, not a RuStore API client;
  /// * the declared config violates the typed policy.
  @override
  List<String> validateRealMode() {
    const noAdapter =
        'RuStore upload requires a project-provided credential adapter; '
        'use dryRun for a readiness plan';
    return [
      noAdapter,
      ...effectivePolicy.validateConfig(
        packageName: packageName,
        versionCode: versionCode,
        versionName: versionName,
      ),
    ];
  }

  /// Staging (shared primitive) + real-bundle-fact verification gate.
  @override
  List<BuildStep> publishSteps(final BuildContext ctx) => [
    StageAabStep(artifactPath: artifactPath),
    if (!dryRun)
      RuStoreArtifactVerificationStep(
        artifact: StageAabStep.aab,
        policy: effectivePolicy,
      ),
  ];

  /// The upload tail. Unreachable through [compile] (real mode is refused
  /// at plan time); kept as a hard stop for direct step composition.
  @override
  BuildStep uploadStep(final BuildContext ctx) => _RuStoreUploadStep(this);
}

class _RuStoreUploadStep extends BuildStep {
  _RuStoreUploadStep(this.target);
  final RuStorePublishTarget target;

  @override
  String get name => 'rustore-upload';
  @override
  Set<Artifact<Object>> get requires => {StageAabStep.aab};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) =>
      Future.value(
        StepResult.failure(
          'RuStore upload requires a project-provided credential adapter; '
          'use dryRun for a readiness plan',
        ),
      );
}
