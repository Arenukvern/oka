import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/oka_android.dart';

import 'agc_publish_step.dart';

/// How AppGallery should receive the Android bundle.
enum HuaweiBundleMode { either, universal, split }

/// Pure, typed AppGallery readiness policy.
///
/// This deliberately lives in `oka_huawei`: GMS and bundle delivery rules are
/// store policy, not generic Android or CLI policy.
class HuaweiDistributionPolicy {
  const HuaweiDistributionPolicy({
    this.bundleMode = HuaweiBundleMode.either,
    this.forbiddenDependencies = const [],
  });

  final HuaweiBundleMode bundleMode;
  final List<String> forbiddenDependencies;

  List<String> validateDependencies(final Iterable<String> coordinates) {
    final issues = <String>[];
    for (final coordinate in coordinates) {
      if (isGmsCoordinate(coordinate) ||
          forbiddenDependencies.any(
            (final prefix) =>
                coordinate == prefix || coordinate.startsWith('$prefix:'),
          )) {
        issues.add(
          'GMS dependency is not allowed in Huawei artifact: $coordinate',
        );
      }
    }
    return issues;
  }

  List<String> validateEntries(final Iterable<String> entries) {
    final values = entries.toSet();
    final issues = <String>[];
    if (!values.any((final e) => e == 'base/manifest/AndroidManifest.xml')) {
      issues.add('AAB is missing base/manifest/AndroidManifest.xml');
    }
    final hasSplit = values.any(
      (final e) => e.startsWith('BUNDLE-METADATA/') || e.startsWith('base/'),
    );
    if (bundleMode == HuaweiBundleMode.universal && !hasSplit) {
      issues.add('Huawei universal bundle must contain the base module');
    }
    if (bundleMode == HuaweiBundleMode.split && !hasSplit) {
      issues.add('Huawei split bundle must contain a base module');
    }
    return issues;
  }
}

/// Result of an offline Huawei artifact readiness check.
class HuaweiArtifactVerification {
  const HuaweiArtifactVerification(this.issues, {this.entries = const []});
  final List<String> issues;
  final List<String> entries;
  bool get ok => issues.isEmpty;
}

Future<HuaweiArtifactVerification> verifyHuaweiArtifact({
  required String aabPath,
  HuaweiDistributionPolicy policy = const HuaweiDistributionPolicy(),
  Iterable<String> dependencies = const [],
}) async {
  final file = File(aabPath);
  if (!await file.exists()) {
    return const HuaweiArtifactVerification(['Huawei AAB does not exist']);
  }
  final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
  final entries = [for (final entry in archive) entry.name];
  return HuaweiArtifactVerification([
    ...policy.validateDependencies(dependencies),
    ...policy.validateEntries(entries),
  ], entries: entries);
}

/// Composition-time/run-time gate for a real Huawei build.
class HuaweiArtifactVerificationStep extends BuildStep {
  HuaweiArtifactVerificationStep({
    this.policy = const HuaweiDistributionPolicy(),
    this.dependencies = const [],
  });

  final HuaweiDistributionPolicy policy;
  final List<String> dependencies;

  @override
  String get name => 'huawei-verify-artifact';

  @override
  Set<Artifact<Object>> get requires => {HuaweiStageAabStep.aabPath};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final path = state[HuaweiStageAabStep.aabPath.id];
    if (path is! String || path.isEmpty) {
      return StepResult.failure('Huawei AAB path is missing');
    }
    final result = await verifyHuaweiArtifact(
      aabPath: path,
      policy: policy,
      dependencies: dependencies,
    );
    return result.ok
        ? StepResult.success({'huawei-artifact': path})
        : StepResult.failure(result.issues.join('; '));
  }
}
