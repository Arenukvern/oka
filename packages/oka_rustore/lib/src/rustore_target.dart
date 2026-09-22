import 'package:oka_core/oka_core.dart';

import 'rustore_policy.dart';

/// Stages an AAB path without touching the filesystem, preserving dry-run.
class RuStoreStageAabStep extends BuildStep {
  RuStoreStageAabStep({this.artifactPath});

  static const aab = Artifact<String>('rustore-aab-path');
  final String? artifactPath;

  @override
  String get name => 'rustore-stage-aab';

  @override
  Set<Artifact<Object>> get provides => {aab};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final path =
        artifactPath ??
        (state['aab-path'] as String? ??
            '${ctx.buildDir}/aab/app-${ctx.mode.name}.aab');
    state[aab.id] = path;
    return StepResult.success({'rustore-aab-path': path});
  }
}

/// RuStore target. Publishing remains dry-run until a project supplies its
/// credential/upload adapter; readiness checks are still typed and composable.
class RuStorePublishTarget extends PublishTarget {
  const RuStorePublishTarget({
    required this.packageName,
    this.targetName = 'publish-rustore',
    this.dryRun = true,
    this.versionCode,
    this.versionName = '',
    this.artifactPath,
    this.policy,
    this.metadataReader,
  });

  final String targetName;
  final String packageName;
  final int? versionCode;
  final String versionName;
  final String? artifactPath;
  final RuStoreDistributionPolicy? policy;
  final RuStoreArtifactMetadata Function(List<String> entries)? metadataReader;

  @override
  final bool dryRun;

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
  String get artifactId => RuStoreStageAabStep.aab.id;
  @override
  Map<String, String> get metadata => {
    'packageName': packageName,
    if (versionCode != null) 'versionCode': '$versionCode',
    if (versionName.isNotEmpty) 'versionName': versionName,
  };

  @override
  List<BuildStep> publishSteps(final BuildContext ctx) => [
    RuStoreStageAabStep(artifactPath: artifactPath),
    if (!dryRun)
      RuStoreArtifactVerificationStep(
        artifact: RuStoreStageAabStep.aab,
        policy: policy ?? RuStoreDistributionPolicy(packageName: packageName),
        metadata:
            metadataReader ??
            (final entries) => RuStoreArtifactMetadata(
              packageName: packageName,
              versionCode: versionCode ?? 0,
              versionName: versionName,
              signatureEntries: [
                for (final entry in entries)
                  if (entry.startsWith('META-INF/') &&
                      (entry.endsWith('.RSA') ||
                          entry.endsWith('.DSA') ||
                          entry.endsWith('.EC')))
                    entry,
              ],
            ),
      ),
  ];

  @override
  BuildStep uploadStep(final BuildContext ctx) => _RuStoreUploadStep(this);
}

class _RuStoreUploadStep extends BuildStep {
  _RuStoreUploadStep(this.target);
  final RuStorePublishTarget target;

  @override
  String get name => 'rustore-upload';
  @override
  Set<Artifact<Object>> get requires => {RuStoreStageAabStep.aab};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) =>
      Future.value(
        StepResult.failure(
          'RuStore upload requires a project-provided credential adapter; '
          'use dryRun for a readiness plan',
        ),
      );
}
