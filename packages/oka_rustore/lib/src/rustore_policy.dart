import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_core/oka_core.dart';

/// Facts RuStore obtains from the signed bundle. Keep this separate from Play:
/// RuStore does not require Play's split/device-delivery semantics.
class RuStoreArtifactMetadata {
  const RuStoreArtifactMetadata({
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    required this.signatureEntries,
  });

  final String packageName;
  final int versionCode;
  final String versionName;
  final List<String> signatureEntries;
}

/// Typed RuStore constraints. All fields are store policy, not CLI flags.
class RuStoreDistributionPolicy {
  const RuStoreDistributionPolicy({
    required this.packageName,
    this.minimumVersionCode,
    this.maximumVersionCode,
    this.versionNamePattern,
    this.requireSignature = true,
  });

  final String packageName;
  final int? minimumVersionCode;
  final int? maximumVersionCode;
  final Pattern? versionNamePattern;
  final bool requireSignature;

  List<String> validate(final RuStoreArtifactMetadata metadata) {
    final issues = <String>[];
    if (metadata.packageName != packageName) {
      issues.add(
        'package name ${metadata.packageName} does not match $packageName',
      );
    }
    if (minimumVersionCode != null &&
        metadata.versionCode < minimumVersionCode!) {
      issues.add('versionCode is below $minimumVersionCode');
    }
    if (maximumVersionCode != null &&
        metadata.versionCode > maximumVersionCode!) {
      issues.add('versionCode is above $maximumVersionCode');
    }
    if (versionNamePattern != null &&
        versionNamePattern!.matchAsPrefix(metadata.versionName) == null) {
      issues.add('versionName does not satisfy $versionNamePattern');
    }
    if (requireSignature && metadata.signatureEntries.isEmpty) {
      issues.add('signed AAB signature entries are missing');
    }
    return issues;
  }
}

/// Checks archive-level facts without invoking bundletool or Play APIs.
Future<List<String>> verifyRuStoreAab({
  required String aabPath,
  required RuStoreDistributionPolicy policy,
  required RuStoreArtifactMetadata Function(List<String> entries) metadata,
}) async {
  final file = File(aabPath);
  if (!await file.exists()) {
    return ['RuStore AAB does not exist'];
  }
  if (!aabPath.toLowerCase().endsWith('.aab')) {
    return ['RuStore requires an Android App Bundle (.aab), not an APK'];
  }
  final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
  final entries = [for (final entry in archive) entry.name];
  if (!entries.contains('base/manifest/AndroidManifest.xml')) {
    return ['AAB is missing base/manifest/AndroidManifest.xml'];
  }
  return policy.validate(metadata(entries));
}

/// Gate inserted before a real RuStore upload. It intentionally does not
/// build device-specific split APKs: that is a Google Play concern.
class RuStoreArtifactVerificationStep extends BuildStep {
  RuStoreArtifactVerificationStep({
    required this.artifact,
    required this.policy,
    required this.metadata,
  });

  final Artifact<String> artifact;
  final RuStoreDistributionPolicy policy;
  final RuStoreArtifactMetadata Function(List<String> entries) metadata;

  @override
  String get name => 'rustore-verify-aab';

  @override
  Set<Artifact<Object>> get requires => {artifact};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final path = state[artifact.id];
    if (path is! String) {
      return StepResult.failure('RuStore AAB path is missing');
    }
    final issues = await verifyRuStoreAab(
      aabPath: path,
      policy: policy,
      metadata: metadata,
    );
    return issues.isEmpty
        ? StepResult.success({'rustore-aab': path})
        : StepResult.failure(issues.join('; '));
  }
}
