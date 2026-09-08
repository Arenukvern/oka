import 'package:oka_core/oka_core.dart';

import '../build/toolchain.dart';
import 'device_steps.dart';

export 'device_steps.dart';

/// The device smoke-test target, shipped by `oka_android` (ADR-0015).
///
/// Compiles to a device pipeline: resolve the newest built APK → `adb
/// install -r` → launch → wait → scan the device log for failure
/// signatures (see [deviceFailureSignatures]). Steps run through the same
/// composition-time artifact validation as builds — before any tool runs.
///
/// Declare it in the composition root (per-project, typed — instead of CLI
/// flags, which the verb/target split replaces):
///
/// ```dart
/// Oka(
///   pipelines: [...],
///   targets: [
///     DeviceTarget(
///       apk: 'build/app/outputs/app-release.apk', // default: newest built
///       package: 'dev.example.app',               // default: aapt2 badging
///       activity: 'dev.example.app.MainActivity',
///       noInstall: true,      // app must already be on the device
///       waitSeconds: 15,
///       deviceId: 'R5CX...',  // multi-device hosts; `-d` forwards here
///     ),
///   ],
/// )
/// ```
///
/// Run with `oka run device` — `oka launch` is a CLI alias of the same
/// dispatch (ADR-0015: verbs never know platforms).
class DeviceTarget extends Target {
  const DeviceTarget({
    this.apk,
    this.package,
    this.activity,
    this.noInstall = false,
    this.waitSeconds = 10,
    this.deviceId,
    this.adbPath,
    this.aapt2Path,
    this.toolchain,
  });

  /// APK to install (default: newest APK under `.oka_cache/build/`).
  final String? apk;

  /// Package name override (default: `aapt2 dump badging` on the APK).
  final String? package;

  /// Launchable-activity override (default: `aapt2 dump badging`).
  final String? activity;

  /// Skip `adb install` — the app must already be on the device. A dead
  /// process after launch is then not attributed to this run.
  final bool noInstall;

  /// Seconds to wait before the device-log scan.
  final int waitSeconds;

  /// Device serial (`adb -s`) — required on multi-device hosts (phone +
  /// emulator); null lets adb pick (single-device setups only). Settable
  /// per-invocation: `oka run device -d <id>` (or `oka launch -d <id>`)
  /// overrides this via the [applyInvocationArgs] contract.
  final String? deviceId;

  /// Injectable tool paths (tests / explicit config); null → [toolchain].
  final String? adbPath;
  final String? aapt2Path;

  /// Injectable toolchain (ADR-0013 T2): null → `state.resolvedToolchain`
  /// → default policy. Composition roots building on the shared store seed
  /// one `ResolvedToolchain` here instead of per-step paths.
  final ResolvedToolchain? toolchain;

  @override
  String get name => 'device';

  @override
  String get description =>
      'Install the newest built APK, launch it, and scan the device log '
      'for failure signatures';

  @override
  List<BuildStep> compile(final BuildContext ctx) => [
        ResolveNewestApkStep(explicitApk: apk),
        if (!noInstall)
          InstallApkStep(
            deviceId: deviceId,
            adbPath: adbPath,
            toolchain: toolchain,
          ),
        LaunchAppStep(
          deviceId: deviceId,
          packageOverride: package,
          activityOverride: activity,
          adbPath: adbPath,
          aapt2Path: aapt2Path,
          toolchain: toolchain,
        ),
        LogcatScanStep(
          waitSeconds: waitSeconds,
          treatMissingProcessAsFailure: !noInstall,
          deviceId: deviceId,
          adbPath: adbPath,
          toolchain: toolchain,
        ),
      ];

  @override
  Set<String> get supportedInvocationArgs => const {'device'};

  @override
  DeviceTarget applyInvocationArgs(final Map<String, String> args) {
    final unknown = args.keys.toSet().difference(supportedInvocationArgs);
    if (unknown.isNotEmpty) {
      throw ArgumentError(
        'target "device" does not accept invocation arg(s): '
        '${unknown.join(', ')} — accepted: device=<serial>.',
      );
    }
    final id = args['device'];
    if (id == null || id.trim().isEmpty) return this;
    return DeviceTarget(
      apk: apk,
      package: package,
      activity: activity,
      noInstall: noInstall,
      waitSeconds: waitSeconds,
      deviceId: id.trim(),
      adbPath: adbPath,
      aapt2Path: aapt2Path,
      toolchain: toolchain,
    );
  }
}
