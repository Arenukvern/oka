import 'dart:convert';

import 'config/build_context.dart';
import 'config/release_verification_options.dart';
import 'pipeline/pipeline.dart';

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

/// The shared pre-upload delivery gate (ADR-0023 §3): every store target
/// that publishes with a [DeliveryVerifier] runs this step between artifact
/// staging and the upload tail. A failed gate (including an unavailable
/// verifier-reported check) is a hard failure — a target must never upload
/// an artifact its verifier did not accept.
///
/// Pure orchestration: the verifier implementation is supplied by the
/// platform package (`AndroidDeliveryVerifier` in oka_android) and wired by
/// the project composition root — oka_core never learns store names.
class DeliveryVerificationStep extends BuildStep {
  DeliveryVerificationStep({
    required this.artifactId,
    required this.verifier,
    this.options = const DeliveryVerificationOptions(),
    this.outputDirName = 'delivery-verification',
  });

  /// The verified-delivery report artifact.
  static const report = Artifact<DeliveryVerificationReport>(
    'delivery-verification-report',
  );

  /// Artifact id verified by this step (e.g. `aab-path`).
  final String artifactId;

  /// Platform-supplied verifier implementation.
  final DeliveryVerifier verifier;

  /// Typed options forwarded to the verifier.
  final DeliveryVerificationOptions options;

  /// Subdirectory of the build dir for verifier outputs (split APKs, specs,
  /// reports).
  final String outputDirName;

  @override
  String get name => 'verify-delivery';

  @override
  Set<Artifact<Object>> get requires => {Artifact<String>(artifactId)};

  @override
  Set<Artifact<Object>> get provides => {report};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final path = state[artifactId];
    if (path is! String || path.isEmpty) {
      return StepResult.failure(
        'artifact "$artifactId" is missing — delivery verification cannot run',
      );
    }
    final outputDirectory = ctx.buildDir.isEmpty
        ? 'delivery-verification'
        : '${ctx.buildDir}/$outputDirName';
    final deliveryReport = await verifier.verify(
      artifact: path,
      outputDirectory: outputDirectory,
      options: options,
      verbose: ctx.verbose,
    );
    state[DeliveryVerificationStep.report.id] = deliveryReport;
    final failedGates = [
      for (final e in deliveryReport.gates.entries)
        if (!e.value) e.key,
    ];
    return deliveryReport.ok
        ? StepResult.success({
            'delivery-verification':
                'ok (${deliveryReport.gates.length} gates)',
          })
        : StepResult.failure(
            'delivery verification failed gates: ${failedGates.join(', ')}'
            '${_reportSuffix(deliveryReport.reportPath)}',
          );
  }
}

String _reportSuffix(final String? reportPath) =>
    reportPath == null ? '' : ' — report: $reportPath';
