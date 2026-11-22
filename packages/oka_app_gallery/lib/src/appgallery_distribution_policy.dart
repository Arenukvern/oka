import 'dart:io';

import 'package:archive/archive.dart';
import 'package:oka_android/oka_android.dart';

import 'agc_publish_step.dart';

/// How AppGallery should receive the Android bundle.
enum AppGalleryBundleMode { either, universal, split }

/// Pure, typed AppGallery readiness policy.
///
/// This deliberately lives in `oka_app_gallery`: GMS and bundle delivery rules are
/// store policy, not generic Android or CLI policy.
class AppGalleryDistributionPolicy {
  const AppGalleryDistributionPolicy({
    this.bundleMode = AppGalleryBundleMode.either,
    this.forbiddenDependencies = const [],
  });

  final AppGalleryBundleMode bundleMode;
  final List<String> forbiddenDependencies;

  List<String> validateDependencies(Iterable<String> coordinates) {
    final issues = <String>[];
    for (final coordinate in coordinates) {
      if (isGmsCoordinate(coordinate) ||
          forbiddenDependencies.any(
            (prefix) =>
                coordinate == prefix || coordinate.startsWith('$prefix:'),
          )) {
        issues.add(
          'GMS dependency is not allowed in AppGallery artifact: $coordinate',
        );
      }
    }
    return issues;
  }

  List<String> validateEntries(Iterable<String> entries) {
    final values = entries.toSet();
    final issues = <String>[];
    if (!values.any((e) => e == 'base/manifest/AndroidManifest.xml')) {
      issues.add('AAB is missing base/manifest/AndroidManifest.xml');
    }
    final hasSplit = values.any(
      (e) => e.startsWith('BUNDLE-METADATA/') || e.startsWith('base/'),
    );
    if (bundleMode == AppGalleryBundleMode.universal && !hasSplit) {
      issues.add('AppGallery universal bundle must contain the base module');
    }
    if (bundleMode == AppGalleryBundleMode.split && !hasSplit) {
      issues.add('AppGallery split bundle must contain a base module');
    }
    return issues;
  }
}

/// Result of an offline AppGallery artifact readiness check.
class AppGalleryArtifactVerification {
  const AppGalleryArtifactVerification(this.issues, {this.entries = const []});
  final List<String> issues;
  final List<String> entries;
  bool get ok => issues.isEmpty;
}

Future<AppGalleryArtifactVerification> verifyAppGalleryArtifact({
  required String aabPath,
  AppGalleryDistributionPolicy policy = const AppGalleryDistributionPolicy(),
  Iterable<String> dependencies = const [],
}) async {
  final file = File(aabPath);
  if (!await file.exists()) {
    return const AppGalleryArtifactVerification(['AppGallery AAB does not exist']);
  }
  final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
  final entries = [for (final entry in archive) entry.name];
  return AppGalleryArtifactVerification([
    ...policy.validateDependencies(dependencies),
    ...policy.validateEntries(entries),
  ], entries: entries);
}

/// Composition-time/run-time gate for a real AppGallery build.
class AppGalleryArtifactVerificationStep extends BuildStep {
  AppGalleryArtifactVerificationStep({
    this.policy = const AppGalleryDistributionPolicy(),
    this.dependencies = const [],
  });

  final AppGalleryDistributionPolicy policy;
  final List<String> dependencies;

  @override
  String get name => 'appgallery-verify-artifact';

  @override
  Set<Artifact<Object>> get requires => {AppGalleryStageAabStep.aabPath};

  @override
  Future<StepResult> run(
    BuildContext ctx,
    PipelineState state,
  ) async {
    final path = state[AppGalleryStageAabStep.aabPath.id];
    if (path is! String || path.isEmpty) {
      return StepResult.failure('AppGallery AAB path is missing');
    }
    final result = await verifyAppGalleryArtifact(
      aabPath: path,
      policy: policy,
      dependencies: dependencies,
    );
    return result.ok
        ? StepResult.success({'appgallery-artifact': path})
        : StepResult.failure(result.issues.join('; '));
  }
}
