import 'package:oka_core/oka_core.dart';

import '../build/toolchain.dart';
import 'device_steps.dart';
import 'launch_failure_signatures.dart';
import 'verify_ladder.dart';

export 'launch_failure_signatures.dart';
export 'verify_ladder.dart';

/// The release verification ladder as a project-declared target
/// (ADR-0015 + ADR-0029 D3). Run with `oka run verify`.
///
/// Walks fixed rungs — artifact provenance → snapshot/engine pairing →
/// install → device health → launch → process alive → Dart main (beacon) →
/// first frame → failure signatures — and renders one report. A failing
/// rung names the cause and fix; an unhealthy device yields an
/// *inconclusive* verdict instead of silent evidence.
///
/// ```dart
/// Oka(
///   pipelines: [...],
///   targets: [
///     VerifyTarget(
///       startupProbe: true,               // beacon proves Dart main() ran
///       extraFailureSignatures: [...],    // project-declared signatures
///       rungs: [MyBackendReadyRungStep()], // custom rungs append
///     ),
///   ],
/// )
/// ```
///
/// With `startupProbe: true`, build with `startupProbe: true` in
/// `FlutterBuild` so the artifact carries the beacon the dart-main rung
/// waits for.
class VerifyTarget extends Target {
  const VerifyTarget({
    this.apk,
    this.package,
    this.activity,
    this.noInstall = false,
    this.startupProbe = false,
    this.processWaitSeconds = 5,
    this.frameBudgetSeconds = 20,
    this.waitSeconds = 8,
    this.maxLoad = 16,
    this.deviceId,
    this.adbPath,
    this.aapt2Path,
    this.toolchain,
    this.rungs = const [],
    this.extraFailureSignatures = const [],
  });

  /// APK to verify (default: newest APK under `.oka_cache/build/`).
  final String? apk;

  /// Package name override (default: `aapt2 dump badging`).
  final String? package;

  /// Launchable-activity override (default: `aapt2 dump badging`).
  final String? activity;

  /// Skip `adb install` — the app must already be on the device.
  final bool noInstall;

  /// Expect the generated startup beacon in the device log (build with
  /// `FlutterBuild(startupProbe: true)`), turning the `dart-main` rung from
  /// a skip into a real check.
  final bool startupProbe;

  /// Seconds to wait before the process-alive check.
  final int processWaitSeconds;

  /// Seconds to wait for the first rendered frame.
  final int frameBudgetSeconds;

  /// Seconds to wait before the failure-signature scan.
  final int waitSeconds;

  /// Host/device load above which rungs report inconclusive.
  final double maxLoad;

  /// Device serial (`adb -s`); settable per-invocation via `device=<serial>`.
  final String? deviceId;

  /// Injectable tool paths (tests / explicit config); null → [toolchain].
  final String? adbPath;
  final String? aapt2Path;

  /// Null → `state.resolvedToolchain` → default policy (ADR-0013 T2).
  final ResolvedToolchain? toolchain;

  /// Custom rungs appended after the builtin ladder, before the report —
  /// the extension point for third-party verification (backend reachable,
  /// feature flag set, …). Each must be a step that records a
  /// [RungVerdict] (extend [RungStep] and the report includes it).
  final List<BuildStep> rungs;

  /// Project-declared failure signatures scanned in addition to the
  /// builtin table.
  final List<FailureSignature> extraFailureSignatures;

  @override
  String get name => 'verify';

  @override
  String get description =>
      'Walk the release verification ladder: provenance, engine/snapshot '
      'pairing, install, device health, launch, Dart main, first frame, '
      'failure signatures';

  @override
  List<BuildStep> compile(final BuildContext ctx) => [
        ResolveNewestApkStep(explicitApk: apk),
        ArtifactProvenanceRungStep(
          deviceId: deviceId,
          adbPath: adbPath,
          toolchain: toolchain,
        ),
        SnapshotPairingRungStep(
          deviceId: deviceId,
          adbPath: adbPath,
          toolchain: toolchain,
        ),
        if (!noInstall)
          InstallApkStep(
            deviceId: deviceId,
            adbPath: adbPath,
            toolchain: toolchain,
          ),
        DeviceHealthRungStep(
          deviceId: deviceId,
          adbPath: adbPath,
          toolchain: toolchain,
          maxLoad: maxLoad,
        ),
        LaunchAppStep(
          deviceId: deviceId,
          packageOverride: package,
          activityOverride: activity,
          adbPath: adbPath,
          aapt2Path: aapt2Path,
          toolchain: toolchain,
        ),
        ProcessAliveRungStep(
          deviceId: deviceId,
          adbPath: adbPath,
          toolchain: toolchain,
          waitSeconds: processWaitSeconds,
        ),
        DartMainBeaconRungStep(
          deviceId: deviceId,
          adbPath: adbPath,
          toolchain: toolchain,
          expectBeacon: startupProbe,
        ),
        FirstFrameRungStep(
          deviceId: deviceId,
          adbPath: adbPath,
          toolchain: toolchain,
          budgetSeconds: frameBudgetSeconds,
        ),
        LogcatScanStep(
          waitSeconds: waitSeconds,
          treatMissingProcessAsFailure: !noInstall,
          deviceId: deviceId,
          adbPath: adbPath,
          toolchain: toolchain,
        ),
        LogcatSignaturesRungStep(
          deviceId: deviceId,
          adbPath: adbPath,
          toolchain: toolchain,
          extraFailureSignatures: extraFailureSignatures,
        ),
        ...rungs,
        VerificationReportStep(),
      ];

  @override
  Set<String> get supportedInvocationArgs => const {'device'};

  @override
  VerifyTarget applyInvocationArgs(final Map<String, String> args) {
    final unknown = args.keys.toSet().difference(supportedInvocationArgs);
    if (unknown.isNotEmpty) {
      throw ArgumentError(
        'target "verify" does not accept invocation arg(s): '
        '${unknown.join(', ')} — accepted: device=<serial>.',
      );
    }
    final id = args['device'];
    if (id == null || id.trim().isEmpty) return this;
    return VerifyTarget(
      apk: apk,
      package: package,
      activity: activity,
      noInstall: noInstall,
      startupProbe: startupProbe,
      processWaitSeconds: processWaitSeconds,
      frameBudgetSeconds: frameBudgetSeconds,
      waitSeconds: waitSeconds,
      maxLoad: maxLoad,
      deviceId: id.trim(),
      adbPath: adbPath,
      aapt2Path: aapt2Path,
      toolchain: toolchain,
      rungs: rungs,
      extraFailureSignatures: extraFailureSignatures,
    );
  }
}
