/// Device-layer pipeline steps behind the ADR-0015 device target.
///
/// This is the Android home of the flow that used to live in the CLI verb
/// layer (`oka launch`): install the newest built APK, launch it, wait, then
/// scan the device log for the classic failure signatures. The CLI never
/// grows for device logic again — `oka launch` is an alias of `oka run
/// device`, and these steps run through the same validated [Pipeline] as
/// builds (ADR-0002 machinery: composition-time artifact validation before
/// any tool runs).
///
/// This closes the feedback loop that static checks cannot: a build can be
/// structurally valid while the app dies on launch (e.g. a plugin class
/// missing from the DEX kills `GeneratedPluginRegistrant` and silently
/// unregisters ALL plugins — the UI then fails with channel errors).
///
/// Failure signatures scanned (see [deviceFailureSignatures]):
/// - `FATAL EXCEPTION` / `Unhandled Exception` — Dart or platform crash
/// - `NoClassDefFoundError` — missing runtime class (dependency gap)
/// - `could not find or invoke the GeneratedPluginRegistrant` — registrant
///   failed → every plugin unregistered
/// - `Error registering plugin` — single-plugin registration failure
/// - `channel-error` / `Unable to establish connection on channel` — plugin
///   not registered while Dart calls into it
library;

import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../android_artifacts.dart';
import '../android_state.dart';
import '../build/toolchain.dart';

/// Device-log failure signatures scanned after launch (name → needle).
///
/// Scanned case-insensitively against the full current-boot log buffer —
/// crashes rarely appear in the `-b crash` buffer alone when they are caught
/// and logged as errors instead.
const deviceFailureSignatures = <String, String>{
  'fatal-exception': 'FATAL EXCEPTION',
  'unhandled-dart-exception': 'Unhandled Exception',
  'missing-class': 'NoClassDefFoundError',
  'registrant-missing':
      'could not find or invoke the GeneratedPluginRegistrant',
  'plugin-register-failed': 'Error registering plugin',
  'channel-error': 'channel-error',
  'pigeon-channel-missing': 'Unable to establish connection on channel',
};

/// Parses `aapt2 dump badging` output into `{package, launchable-activity}`.
///
/// Pure — unit-tested independently of the tool. Missing keys are simply
/// absent from the map; callers decide whether that is fatal.
Map<String, String> parseAapt2Badging(final String output) {
  final out = <String, String>{};
  for (final line in output.split('\n')) {
    if (line.startsWith('package:')) {
      final m = RegExp("name='([^']+)'").firstMatch(line);
      if (m != null) out['package'] = m.group(1)!;
    }
    if (line.startsWith('launchable-activity:')) {
      final m = RegExp("name='([^']+)'").firstMatch(line);
      if (m != null) out['launchable-activity'] = m.group(1)!;
    }
  }
  return out;
}

/// Scans a device log dump for [deviceFailureSignatures]
/// (case-insensitive). Returns the subset of signatures found.
Map<String, String> scanLogForFailureSignatures(final String log) {
  final found = <String, String>{};
  final lowered = log.toLowerCase();
  for (final entry in deviceFailureSignatures.entries) {
    if (lowered.contains(entry.value.toLowerCase())) {
      found[entry.key] = entry.value;
    }
  }
  return found;
}

/// Device steps resolve tools through the [ResolvedToolchain] policy
/// (ADR-0013, T2): explicit constructor path → `state.resolvedToolchain`
/// (seeded by the platform pipeline when present) → the default policy.
/// Nothing here calls the deprecated locator wrapper — provisioning of a
/// missing adb goes through the store-backed AndroidDeviceProvisioner.
ResolvedToolchain _resolveToolchain(
  final ResolvedToolchain? injected,
  final PipelineState state,
) =>
    injected ?? state.resolvedToolchain ?? ResolvedToolchain();

/// Newest APK across `.oka_cache/build/*/app-*.apk` (including the
/// `*-aab` sibling layout), or null when none exists.
Future<String?> findNewestBuiltApk(final String projectPath) async {
  final candidates = <String>[];
  final buildRoot = Directory(
    p.join(projectPath, '.oka_cache', 'build'),
  );
  if (!buildRoot.existsSync()) return null;
  await for (final modeDir in buildRoot.list()) {
    if (modeDir is! Directory) continue;
    final aabDir = Directory(p.join(modeDir.path, 'aab'));
    final dirs = <Directory>[modeDir, if (aabDir.existsSync()) aabDir];
    for (final d in dirs) {
      await for (final f in d.list()) {
        if (f is File && p.basename(f.path).endsWith('.apk')) {
          candidates.add(f.path);
        }
      }
    }
  }
  if (candidates.isEmpty) return null;
  candidates.sort(
    (final a, final b) =>
        File(b).lastModifiedSync().compareTo(File(a).lastModifiedSync()),
  );
  return candidates.first;
}

/// Resolves the APK the device flow operates on: [explicitApk] when given,
/// otherwise the newest APK under `.oka_cache/build/`. Provides [apkPath].
class ResolveNewestApkStep extends BuildStep {
  ResolveNewestApkStep({this.explicitApk});

  /// Explicit APK path (typed target config instead of a CLI flag).
  final String? explicitApk;

  @override
  String get name => 'resolve-device-apk';

  @override
  Set<Artifact<Object>> get provides => {apkPath};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    if (explicitApk != null) {
      if (!File(explicitApk!).existsSync()) {
        return StepResult.failure('not found: $explicitApk');
      }
      state[apkPath.id] = explicitApk;
      return StepResult.success({apkPath.id: explicitApk});
    }
    final newest = await findNewestBuiltApk(ctx.projectPath);
    if (newest == null) {
      return StepResult.failure(
        'No APK found — run `oka build apk` first, or declare '
        'DeviceTarget(apk: ...) in tool/oka_pipeline.dart.',
      );
    }
    state[apkPath.id] = newest;
    return StepResult.success({apkPath.id: newest});
  }
}

/// `adb install -r` the resolved APK, with the classic failure
/// classification (signing-key mismatch, no device).
class InstallApkStep extends BuildStep {
  InstallApkStep({this.adbPath, this.toolchain});

  /// Injectable adb path (tests / explicit config); null → toolchain.
  final String? adbPath;

  /// Null → [PipelineState.resolvedToolchain] → default (ADR-0013 T2).
  final ResolvedToolchain? toolchain;

  @override
  String get name => 'device-install';

  @override
  Set<Artifact<Object>> get requires => {apkPath};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final apk = state[apkPath.id]! as String;
    final String adb;
    try {
      adb = adbPath ??
          await _resolveToolchain(toolchain, state).findAdb();
    } on ToolchainException {
      return StepResult.failure(
        'adb not found — install platform-tools (oka get android-sdk)',
      );
    }

    print('📲 Installing ${p.basename(apk)}');
    final install = await Process.run(adb, ['install', '-r', apk]);
    if (install.exitCode != 0 ||
        '${install.stdout}${install.stderr}'.contains('Failure')) {
      final output = '${install.stdout}${install.stderr}'.trim();
      if (output.contains('INCOMPATIBLE')) {
        print(
          '\n❌ Signing-key mismatch: the device already has this app '
          'installed with a different key. Never uninstall an app with '
          'user data — sign with the same key instead '
          '(android/key.properties).',
        );
      } else if (output.contains('not found') ||
          output.contains('no devices')) {
        print('\n❌ No device connected. Reconnect the phone and re-run.');
      } else {
        print('\n❌ Install failed:\n$output');
      }
      return StepResult.failure('adb install failed for ${p.basename(apk)}');
    }
    print('✅ Installed');
    return StepResult.success();
  }
}

/// Resolves package + launchable activity (typed target config first, then
/// `aapt2 dump badging` on the APK), clears the device log buffer, and
/// starts the activity.
class LaunchAppStep extends BuildStep {
  LaunchAppStep({
    this.packageOverride,
    this.activityOverride,
    this.adbPath,
    this.aapt2Path,
    this.toolchain,
  });

  /// Typed target config wins over badging (ADR-0015: targets are values).
  final String? packageOverride;
  final String? activityOverride;

  /// Injectable tool paths (tests / explicit config); null → toolchain.
  final String? adbPath;
  final String? aapt2Path;

  /// Null → [PipelineState.resolvedToolchain] → default (ADR-0013 T2).
  final ResolvedToolchain? toolchain;

  @override
  String get name => 'device-launch';

  @override
  Set<Artifact<Object>> get requires => {apkPath};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final apk = state[apkPath.id]! as String;
    var badging = const <String, String>{};
    if (packageOverride == null || activityOverride == null) {
      badging = await _badging(apk, state);
    }
    final packageName = packageOverride ?? badging['package'];
    final activity = activityOverride ?? badging['launchable-activity'];
    if (packageName == null || packageName.isEmpty) {
      return StepResult.failure(
        'Could not determine package name — declare '
        'DeviceTarget(package: ...) in tool/oka_pipeline.dart.',
      );
    }
    if (activity == null || activity.isEmpty) {
      return StepResult.failure(
        'Could not determine launchable activity — declare '
        'DeviceTarget(activity: ...) in tool/oka_pipeline.dart.',
      );
    }

    print('🚀 Starting $activity');
    final adb = await _findAdb(state);
    // Clear the log buffer first — older runs (or other apps) must not
    // produce false failure signatures in the scan below.
    await Process.run(adb, ['logcat', '-c']);
    final start = await Process.run(adb, [
      'shell',
      'am',
      'start',
      '-n',
      '$packageName/$activity',
    ]);
    if (start.exitCode != 0) {
      return StepResult.failure(
        'am start failed:\n${start.stdout}${start.stderr}',
      );
    }
    state['device_package'] = packageName;
    return StepResult.success({'device_package': packageName});
  }

  Future<String> _findAdb(final PipelineState state) => adbPath != null
      ? Future.value(adbPath)
      : _resolveToolchain(toolchain, state).findAdb();

  /// Minimal `aapt2 dump badging` reader ([parseAapt2Badging]). An absent
  /// aapt2 yields an empty map — the caller reports the actionable error.
  Future<Map<String, String>> _badging(
    final String apk,
    final PipelineState state,
  ) async {
    String? aapt2;
    if (aapt2Path != null) {
      aapt2 = aapt2Path;
    } else {
      try {
        aapt2 = await _resolveToolchain(toolchain, state).findAapt2();
      } on ToolchainException {
        return const {};
      }
    }
    if (aapt2 == null) return const {};
    final r = await Process.run(aapt2, ['dump', 'badging', apk]);
    return parseAapt2Badging(r.stdout as String);
  }
}

/// Waits [waitSeconds], checks the process is alive (`pidof`), then scans
/// the full device log buffer for [deviceFailureSignatures] and reports.
class LogcatScanStep extends BuildStep {
  LogcatScanStep({
    this.waitSeconds = 10,
    this.treatMissingProcessAsFailure = true,
    this.adbPath,
    this.toolchain,
  });

  /// Seconds to wait before scanning (lets the app crash if it will).
  final int waitSeconds;

  /// When the flow skipped install (app already on device), a dead process
  /// after `am start` is not attributable to this run — parity with the
  /// historical `--no-install` semantics.
  final bool treatMissingProcessAsFailure;

  /// Injectable adb path (tests / explicit config); null → toolchain.
  final String? adbPath;

  /// Null → [PipelineState.resolvedToolchain] → default (ADR-0013 T2).
  final ResolvedToolchain? toolchain;

  @override
  String get name => 'device-logcat-scan';

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final packageName =
        (state['device_package'] as String?) ?? '';
    print('⏳ Waiting ${waitSeconds}s before scanning the device log...');
    await Future<void>.delayed(Duration(seconds: waitSeconds));

    final String adb;
    try {
      adb = adbPath ??
          await _resolveToolchain(toolchain, state).findAdb();
    } on ToolchainException {
      return StepResult.failure(
        'adb not found — install platform-tools (oka get android-sdk)',
      );
    }
    final pid = await _pidOf(adb, packageName);
    final r = await Process.run(adb, ['logcat', '-d']);
    final scan = scanLogForFailureSignatures('${r.stdout}${r.stderr}');
    _report(packageName: packageName, pid: pid, scan: scan);

    final alive = pid != null && pid.isNotEmpty;
    final failed = scan.isNotEmpty ||
        (!alive && treatMissingProcessAsFailure);
    if (!failed) return StepResult.success();
    final why = [
      if (scan.isNotEmpty)
        'failure signatures in device log: ${scan.keys.join(', ')}',
      if (!alive && treatMissingProcessAsFailure)
        'process died after launch',
    ].join('; ');
    return StepResult.failure('device smoke test failed — $why');
  }

  Future<String?> _pidOf(final String adb, final String packageName) async {
    final r = await Process.run(adb, ['shell', 'pidof', packageName]);
    return (r.stdout as String).trim();
  }

  void _report({
    required final String packageName,
    required final String? pid,
    required final Map<String, String> scan,
  }) {
    print('');
    if (pid != null && pid.isNotEmpty) {
      print('✅ Process alive (pid $pid)');
    } else {
      print('💀 Process not running — it died after launch');
    }
    if (scan.isEmpty) {
      print('✅ No failure signatures in device log');
    } else {
      print('⚠️  Failure signatures found in device log:');
      for (final entry in scan.entries) {
        print('   - ${entry.key}: "${entry.value}"');
      }
      print('');
      print('   Follow up with:');
      print(
        '     adb logcat -d | grep -iE "FATAL|NoClassDefFound|registering"',
      );
      print('   Docs: docs/guides/gradle_migration.md (diagnosis section)');
    }
  }
}
