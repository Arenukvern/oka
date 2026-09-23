import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_core/oka_core.dart';

/// Typed RuStore constraints. All fields are store policy, not CLI flags.
///
/// Split into two honest halves (ADR-0023 §3):
///
/// * [validateConfig] — a pure function of the **declared target config**
///   (package name, versions). Runs at composition/plan time; it validates
///   configuration, not the artifact.
/// * [verifyRuStoreAab] — checks **real bundle facts** (the archive): the
///   file exists, is an `.aab`, contains the base manifest, and — when
///   [requireSignature] — carries v1 JAR signature entries. oka does not
///   pretend to parse the proto manifest; package/version facts are config
///   validation, never bundle-derived.
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

  /// Validates the *declared* target configuration against this policy.
  /// A `null` [versionCode] means "not declared" — acceptable unless the
  /// policy pins a range.
  List<String> validateConfig({
    required final String packageName,
    required final int? versionCode,
    required final String versionName,
  }) {
    final issues = <String>[];
    if (packageName != this.packageName) {
      issues.add(
        'target packageName "$packageName" does not match policy '
        '"$this.packageName"',
      );
    }
    if (minimumVersionCode != null &&
        versionCode != null &&
        versionCode < minimumVersionCode!) {
      issues.add('versionCode $versionCode is below $minimumVersionCode');
    }
    if (maximumVersionCode != null &&
        versionCode != null &&
        versionCode > maximumVersionCode!) {
      issues.add('versionCode $versionCode is above $maximumVersionCode');
    }
    if (versionNamePattern != null &&
        versionName.isNotEmpty &&
        versionNamePattern!.matchAsPrefix(versionName) == null) {
      issues.add(
        'versionName "$versionName" does not satisfy '
        '$versionNamePattern',
      );
    }
    return issues;
  }
}

/// Checks archive-level facts without invoking bundletool or store APIs.
/// Returns policy issues for the real bundle only.
Future<List<String>> verifyRuStoreAab({
  required String aabPath,
  required RuStoreDistributionPolicy policy,
}) async {
  final file = File(aabPath);
  if (!await file.exists()) {
    return ['RuStore AAB does not exist: $aabPath'];
  }
  if (!aabPath.toLowerCase().endsWith('.aab')) {
    return ['RuStore requires an Android App Bundle (.aab), not an APK'];
  }
  final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
  final entries = [for (final entry in archive) entry.name];
  final issues = <String>[];
  if (!entries.contains('base/manifest/AndroidManifest.xml')) {
    issues.add('AAB is missing base/manifest/AndroidManifest.xml');
  }
  if (policy.requireSignature) {
    final hasSignature = entries.any(
      (final entry) =>
          entry.startsWith('META-INF/') &&
          (entry.endsWith('.RSA') ||
              entry.endsWith('.DSA') ||
              entry.endsWith('.EC')),
    );
    if (!hasSignature) {
      issues.add('signed AAB signature entries are missing (META-INF)');
    }
  }
  return issues;
}

/// Gate inserted before a real RuStore upload. It intentionally does not
/// build device-specific split APKs: that is a Google Play concern.
class RuStoreArtifactVerificationStep extends BuildStep {
  RuStoreArtifactVerificationStep({
    required this.artifact,
    required this.policy,
  });

  final Artifact<String> artifact;
  final RuStoreDistributionPolicy policy;

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
    final issues = await verifyRuStoreAab(aabPath: path, policy: policy);
    return issues.isEmpty
        ? StepResult.success({'rustore-aab': path})
        : StepResult.failure(issues.join('; '));
  }
}
