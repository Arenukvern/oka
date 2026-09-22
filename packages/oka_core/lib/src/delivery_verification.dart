import 'dart:convert';

import 'config/release_verification_options.dart';

/// Shared contracts for verifying a built artifact through a delivery target.
///
/// The contract deliberately knows nothing about an app store or a platform
/// tool. Platform packages provide the implementation and interpret the
/// platform-specific options.
class DeliveryVerificationReport {
  const DeliveryVerificationReport({
    required this.artifact,
    required this.artifactSha256,
    required this.artifactBytes,
    required this.abis,
    required this.gates,
    this.deviceSpec,
    this.generatedApks,
    this.installAttempted = false,
    this.launchAttempted = false,
    this.metadata = const {},
    this.reportPath,
  });

  final String artifact;
  final String artifactSha256;
  final int artifactBytes;
  final List<String> abis;
  final Map<String, bool> gates;
  final String? deviceSpec;
  final List<String>? generatedApks;
  final bool installAttempted;
  final bool launchAttempted;
  final Map<String, Object?> metadata;
  final String? reportPath;

  String get path => reportPath ?? artifact;
  bool get ok => gates.values.every((value) => value);

  Map<String, Object?> toJson() => {
        'artifact': artifact,
        'artifact_sha256': artifactSha256,
        'artifact_bytes': artifactBytes,
        'abis': abis,
        'device_spec': deviceSpec,
        'generated_apks': generatedApks,
        'install_attempted': installAttempted,
        'launch_attempted': launchAttempted,
        'metadata': metadata,
        'gates': gates,
        'ok': ok,
      };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());
}

/// A delivery implementation supplied by a platform package.
// This is intentionally a one-method interface: verifier implementations are
// target-specific plugins selected by project-declared distribution targets.
// ignore: one_member_abstracts
abstract interface class DeliveryVerifier {
  Future<DeliveryVerificationReport> verify({
    required String artifact,
    required String outputDirectory,
    DeliveryVerificationOptions options,
    bool verbose,
  });
}
