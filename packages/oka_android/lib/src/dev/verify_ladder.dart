/// The release verification ladder (ADR-0029 D3): fixed rungs from artifact
/// to first frame, each a step with a typed verdict — so "does the release
/// start?" has a one-command, evidence-backed answer instead of a logcat
/// session.
///
/// Rungs are ordinary [BuildStep]s: they compose into [Pipeline]s, pass
/// through composition-time artifact validation, and third parties add
/// their own rungs by appending steps that record verdicts:
///
/// ```dart
/// VerifyTarget(
///   rungs: [
///     MyBackendReadyRungStep(),   // records its own verdict
///   ],
///   extraFailureSignatures: [mySignature],
/// )
/// ```
///
/// Run `oka run verify`. A failing rung fails the run and names the fix
/// (failure signatures are data — see `launch_failure_signatures.dart`).
/// `RungStatus.inconclusiveDevice` is a first-class outcome: an unhealthy
/// device or overloaded host never produces a silent false negative.
library;

import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';

import '../android_artifacts.dart';
import '../android_state.dart';
import '../build/apk_layout.dart';
import '../build/artifact_checks.dart';
import '../build/provenance.dart';
import '../build/startup_probe.dart';
import '../build/toolchain.dart';
import 'adb_tool.dart';
import 'launch_failure_signatures.dart';

/// Outcome of one ladder rung.
enum RungStatus { passed, failed, inconclusiveDevice, skipped }

/// Typed verdict of one rung, JSON-encodable for the report artifact.
class RungVerdict {
  const RungVerdict(
    this.rung,
    this.status, {
    this.detail = '',
    this.evidence = const {},
  });

  final String rung;
  final RungStatus status;
  final String detail;
  final Map<String, Object?> evidence;

  bool get passed => status == RungStatus.passed;
  bool get blocked => status == RungStatus.inconclusiveDevice;

  Map<String, Object?> toJson() => {
    'rung': rung,
    'status': status.name,
    'detail': detail,
    'evidence': evidence,
  };

  // Mirrors RungVerdict.encodeLine.
  // ignore: prefer_constructors_over_static_methods
  static RungVerdict fromJson(final Map<String, dynamic> json) =>
      RungVerdict(
        json['rung']! as String,
        RungStatus.values.byName(json['status']! as String),
        detail: (json['detail'] ?? '') as String,
        evidence:
            (json['evidence'] as Map<String, Object?>?) ??
            const <String, Object?>{},
      );

  String encodeLine() => jsonEncode(toJson());

  String get statusGlyph => switch (status) {
    RungStatus.passed => '✅',
    RungStatus.failed => '❌',
    RungStatus.inconclusiveDevice => '⚠️ ',
    RungStatus.skipped => '⏭️ ',
  };

  @override
  String toString() =>
      '$statusGlyph $rung — ${status.name}${detail.isEmpty ? '' : ': $detail'}';
}

/// Signature of the adb invocation a rung makes — injectable so ladder
/// rungs are unit-testable without a device.
typedef AdbInvoker =
    Future<ProcessResult> Function(String adb, List<String> args);

Future<ProcessResult> _defaultAdb(
  final String adb,
  final List<String> args,
) => Process.run(adb, args);

/// Shared plumbing for rung steps: resolve adb, invoke, record verdict.
abstract class RungStep extends BuildStep {
  RungStep({
    this.deviceId,
    this.adbPath,
    this.toolchain,
    this.runAdb = _defaultAdb,
  });

  /// Device serial (`adb -s`); null = single device.
  final String? deviceId;
  final String? adbPath;
  final ResolvedToolchain? toolchain;
  final AdbInvoker runAdb;

  @override
  Set<Artifact<Object>> get provides => {verificationVerdicts};

  ResolvedToolchain _toolchain(final PipelineState state) =>
      toolchain ?? state.resolvedToolchain ?? ResolvedToolchain();

  Future<String> findAdb(final PipelineState state) async =>
      adbPath ?? await _toolchain(state).findAdb();

  /// Records the verdict into the report artifact.
  void record(final PipelineState state, final RungVerdict verdict) {
    state.addVerificationVerdict(verdict.encodeLine());
    // ignore: avoid_print
    print(verdict);
  }
}

// ── Pure helpers (unit-tested without a device) ────────────────────────

/// Parses `Total frames rendered: N` out of `dumpsys gfxinfo` output.
int parseRenderedFrames(final String gfxinfoOutput) {
  final m = RegExp(
    r'Total frames rendered:\s*(\d+)',
  ).firstMatch(gfxinfoOutput);
  return m == null ? 0 : int.parse(m.group(1)!);
}

/// Decides device health from raw probes. Pure.
///
/// [bootCompleted] — `sys.boot_completed` ("1" = booted); [loadAvg1] —
/// one-minute load from `/proc/loadavg`; [anrInFocus] — the window focus
/// line contains "Application Not Responding" (a systemui ANR wedges the
/// whole display and poisons every other observation).
RungVerdict evaluateDeviceHealth({
  required final String bootCompleted,
  required final double loadAvg1,
  required final bool anrInFocus,
  final double maxLoad = 16,
}) {
  if (bootCompleted.trim() != '1') {
    return RungVerdict(
      'device-health',
      RungStatus.inconclusiveDevice,
      detail: 'device not booted (sys.boot_completed='
          '${bootCompleted.trim()})',
    );
  }
  if (anrInFocus) {
    return const RungVerdict(
      'device-health',
      RungStatus.inconclusiveDevice,
      detail:
          'a system ANR dialog is in focus (systemui wedged) — launch '
          'evidence from this device is untrustworthy; reboot the device '
          'or use a fresh one',
      evidence: {
        'lesson':
            'docs/evidence/android-release-engine-pairing-2026-09-27.mdx',
      },
    );
  }
  if (loadAvg1 > maxLoad) {
    return RungVerdict(
      'device-health',
      RungStatus.inconclusiveDevice,
      detail:
          'host load $loadAvg1 exceeds $maxLoad — rendering/timing evidence '
          'is untrustworthy under this load',
    );
  }
  return RungVerdict(
    'device-health',
    RungStatus.passed,
    detail: 'booted, load $loadAvg1, no ANR dialog in focus',
  );
}

// ── Rung steps ─────────────────────────────────────────────────────────

/// Rung: the artifact carries a provenance record and the staged binaries
/// match its hashes. Old artifacts (no record) fail loudly — the ladder
/// must not bless an unattested APK.
class ArtifactProvenanceRungStep extends RungStep {
  ArtifactProvenanceRungStep({
    super.deviceId,
    super.adbPath,
    super.toolchain,
    super.runAdb,
  });

  @override
  String get name => 'artifact-provenance-rung';

  @override
  Set<Artifact<Object>> get requires => {apkPath};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final apk = state[apkPath.id] as String?;
    if (apk == null || !File(apk).existsSync()) {
      return StepResult.failure(
        'artifact-provenance-rung: no built artifact to verify',
      );
    }
    final provenance = await readProvenanceFromArtifact(apk);
    if (provenance == null) {
      record(
        state,
        RungVerdict(
          'artifact-provenance',
          RungStatus.failed,
          detail:
              'no oka-provenance.json inside $apk — built before ADR-0029 '
              'D1; rebuild with `oka build` to attest, then verify',
        ),
      );
      return StepResult.success();
    }
    // Spot-check: the recorded libflutter hash must match the artifact's
    // libflutter.so for the primary ABI.
    final abi = state.abis.isEmpty ? 'arm64-v8a' : normalizeAbi(state.abis.first);
    final libflutter = state.libflutterByAbi[normalizeAbi(abi)];
    if (libflutter != null && File(libflutter).existsSync()) {
      final recorded = provenance.fact(factEngineLibflutterSha256) as String?;
      if (recorded != null) {
        final actual = await fileSha256(libflutter);
        if (actual != recorded) {
          record(
            state,
            const RungVerdict(
              'artifact-provenance',
              RungStatus.failed,
              detail:
                  'staged libflutter.so hash does not match the provenance '
                  'record — the artifact was tampered with or the record is '
                  'stale',
            ),
          );
          return StepResult.success();
        }
      }
    }
    record(
      state,
      RungVerdict(
        'artifact-provenance',
        RungStatus.passed,
        detail: '${provenance.facts.length} fact(s) present',
        evidence: {
          for (final f in provenance.facts) f.key: f.value,
        },
      ),
    );
    return StepResult.success();
  }
}

/// Rung: snapshot ↔ engine pairing on the built artifact (delegates to the
/// same pure logic packaging validates with — see [SnapshotEnginePairingCheck]).
class SnapshotPairingRungStep extends RungStep {
  SnapshotPairingRungStep({
    super.deviceId,
    super.adbPath,
    super.toolchain,
    super.runAdb,
  });

  @override
  String get name => 'snapshot-pairing-rung';

  @override
  Set<Artifact<Object>> get requires => {apkPath};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final check = const SnapshotEnginePairingCheck().check(
      ArtifactCheckContext(ctx, state),
    );
    final verdict = await check;
    record(
      state,
      RungVerdict(
        'snapshot-pairing',
        verdict.passed
            ? RungStatus.passed
            : RungStatus.failed,
        detail: verdict.detail.isEmpty ? verdict.checkName : verdict.detail,
      ),
    );
    return StepResult.success();
  }
}

/// Rung: is the host+device trustworthy at all? Fails-soft with
/// [RungStatus.inconclusiveDevice] so downstream rungs are reported as
/// unverified instead of silently passing/failing on poisoned evidence.
class DeviceHealthRungStep extends RungStep {
  DeviceHealthRungStep({
    super.deviceId,
    super.adbPath,
    super.toolchain,
    super.runAdb,
    this.maxLoad = 16,
  });

  /// Host/device load above which timing evidence is untrustworthy.
  final double maxLoad;

  @override
  String get name => 'device-health-rung';

  @override
  Set<Artifact<Object>> get requires => {apkPath};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final String adb;
    try {
      adb = await findAdb(state);
    } on ToolchainException {
      return StepResult.failure(
        'device-health-rung: adb not found — install platform-tools',
      );
    }
    final boot = await runAdb(adb, [
      ...adbSerialArgs(deviceId),
      'shell',
      'getprop',
      'sys.boot_completed',
    ]);
    final load = await runAdb(adb, [
      ...adbSerialArgs(deviceId),
      'shell',
      'cat',
      '/proc/loadavg',
    ]);
    final focus = await runAdb(adb, [
      ...adbSerialArgs(deviceId),
      'shell',
      'dumpsys',
      'window',
    ]);
    final loadLine = (load.stdout as String).trim().split(' ').first;
    record(
      state,
      evaluateDeviceHealth(
        bootCompleted: boot.stdout as String,
        loadAvg1: double.tryParse(loadLine) ?? 0,
        anrInFocus: (focus.stdout as String).contains(
          'Application Not Responding',
        ),
        maxLoad: maxLoad,
      ),
    );
    return StepResult.success();
  }
}

/// Rung: the app process is alive [waitSeconds] after launch.
class ProcessAliveRungStep extends RungStep {
  ProcessAliveRungStep({
    super.deviceId,
    super.adbPath,
    super.toolchain,
    super.runAdb,
    this.waitSeconds = 5,
  });

  final int waitSeconds;

  @override
  String get name => 'process-alive-rung';

  @override
  Set<Artifact<Object>> get requires => {apkPath};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final packageName = state['device_package'] as String? ?? '';
    if (packageName.isEmpty) {
      return StepResult.failure(
        'process-alive-rung: no package name — place after device-launch',
      );
    }
    await Future<void>.delayed(Duration(seconds: waitSeconds));
    final adb = await findAdb(state);
    final r = await runAdb(adb, [
      ...adbSerialArgs(deviceId),
      'shell',
      'pidof',
      packageName,
    ]);
    final pid = (r.stdout as String).trim();
    record(
      state,
      pid.isEmpty
          ? const RungVerdict(
              'process-alive',
              RungStatus.failed,
              detail: 'process died after launch',
            )
          : RungVerdict(
              'process-alive',
              RungStatus.passed,
              detail: 'pid $pid',
            ),
    );
    return StepResult.success();
  }
}

/// Rung: the generated startup beacon proves Dart `main()` entered (and
/// ideally returned) in a release build — no app surgery (ADR-0029 D7).
///
/// Compose `VerifyTarget(startupProbe: true)` and build with
/// `FlutterBuild.startupProbe: true`; without the probe the rung reports
/// `skipped` with the exact composition snippet, never a false pass.
class DartMainBeaconRungStep extends RungStep {
  DartMainBeaconRungStep({
    super.deviceId,
    super.adbPath,
    super.toolchain,
    super.runAdb,
    this.expectBeacon = false,
    this.waitSeconds = 3,
  });

  /// Whether the artifact was built with `FlutterBuild.startupProbe`.
  final bool expectBeacon;
  final int waitSeconds;

  @override
  String get name => 'dart-main-rung';

  @override
  Set<Artifact<Object>> get requires => {apkPath};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    if (!expectBeacon) {
      record(
        state,
        const RungVerdict(
          'dart-main',
          RungStatus.skipped,
          detail:
              'no startup beacon expected — compose VerifyTarget( '
              'startupProbe: true) and build with '
              'FlutterBuild(startupProbe: true) to check main() directly',
        ),
      );
      return StepResult.success();
    }
    await Future<void>.delayed(Duration(seconds: waitSeconds));
    final adb = await findAdb(state);
    final r = await runAdb(adb, adbLogcatDumpArgs(serial: deviceId));
    final log = '${r.stdout}${r.stderr}';
    final entered = log.contains(startupBeaconEnteredNeedle);
    final returned = log.contains(startupBeaconReturnedNeedle);
    record(
      state,
      entered
          ? RungVerdict(
              'dart-main',
              RungStatus.passed,
              detail: returned
                  ? 'main entered and returned'
                  : 'main entered (still running or hung inside main)',
            )
          : const RungVerdict(
              'dart-main',
              RungStatus.failed,
              detail:
                  'startup beacon never appeared — Dart main() never ran '
                  '(engine/snapshot layer; see the pairing rung)',
            ),
    );
    return StepResult.success();
  }
}

/// Rung: at least one frame rendered within [budgetSeconds].
class FirstFrameRungStep extends RungStep {
  FirstFrameRungStep({
    super.deviceId,
    super.adbPath,
    super.toolchain,
    super.runAdb,
    this.budgetSeconds = 20,
    this.pollSeconds = 2,
  });

  final int budgetSeconds;
  final int pollSeconds;

  @override
  String get name => 'first-frame-rung';

  @override
  Set<Artifact<Object>> get requires => {apkPath};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final packageName = state['device_package'] as String? ?? '';
    if (packageName.isEmpty) {
      return StepResult.failure(
        'first-frame-rung: no package name — place after device-launch',
      );
    }
    final adb = await findAdb(state);
    final deadline = DateTime.now().add(Duration(seconds: budgetSeconds));
    var frames = 0;
    while (DateTime.now().isBefore(deadline)) {
      final r = await runAdb(adb, [
        ...adbSerialArgs(deviceId),
        'shell',
        'dumpsys',
        'gfxinfo',
        packageName,
      ]);
      frames = parseRenderedFrames(r.stdout as String);
      if (frames > 0) break;
      await Future<void>.delayed(Duration(seconds: pollSeconds));
    }
    record(
      state,
      frames > 0
          ? RungVerdict(
              'first-frame',
              RungStatus.passed,
              detail: '$frames frame(s) rendered',
            )
          : RungVerdict(
              'first-frame',
              RungStatus.failed,
              detail:
                  'no frames rendered within ${budgetSeconds}s — the app is '
                  'stuck before the first frame',
            ),
    );
    return StepResult.success();
  }
}

/// Failure-signature scan over the device log, with cause/fix/evidence from
/// the table (ADR-0029 D5) plus project extras.
class LogcatSignaturesRungStep extends RungStep {
  LogcatSignaturesRungStep({
    super.deviceId,
    super.adbPath,
    super.toolchain,
    super.runAdb,
    this.extraFailureSignatures = const [],
  });

  /// Project-declared signatures composed on top of the builtin table.
  final List<FailureSignature> extraFailureSignatures;

  @override
  String get name => 'logcat-signatures-rung';

  @override
  Set<Artifact<Object>> get requires => {apkPath};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final adb = await findAdb(state);
    final r = await runAdb(adb, adbLogcatDumpArgs(serial: deviceId));
    final log = '${r.stdout}${r.stderr}';
    final matches = scanFailureSignatures(
      log,
      signatures: [...builtinFailureSignatures, ...extraFailureSignatures],
    );
    if (matches.isEmpty) {
      record(
        state,
        const RungVerdict(
          'logcat-signatures',
          RungStatus.passed,
          detail: 'no known failure signatures',
        ),
      );
      return StepResult.success();
    }
    // Record the most specific match as the failed rung; print all.
    for (final m in matches) {
      // ignore: avoid_print
      print('   ⚠️  ${m.signature.id}: "${m.line}"');
      // ignore: avoid_print
      print('      cause: ${m.signature.cause}');
      // ignore: avoid_print
      print('      fix:   ${m.signature.fix}');
      if (m.signature.evidence.isNotEmpty) {
        // ignore: avoid_print
        print('      docs:  ${m.signature.evidence}');
      }
    }
    final first = matches.first;
    record(
      state,
      RungVerdict(
        'logcat-signatures',
        RungStatus.failed,
        detail: '${first.signature.id} — ${first.signature.cause}',
        evidence: {
          'fix': first.signature.fix,
          if (first.signature.evidence.isNotEmpty)
            'evidence': first.signature.evidence,
          'matches': matches.map((final m) => m.toJson()).toList(),
        },
      ),
    );
    return StepResult.success();
  }
}

/// Renders the ladder report and turns it into the run's exit: any failed
/// rung fails the run; an inconclusive device fails with distinct guidance
/// (never a silent pass); all-pass prints the ladder summary.
class VerificationReportStep extends BuildStep {
  VerificationReportStep();

  @override
  String get name => 'verification-report';

  @override
  Set<Artifact<Object>> get requires => {verificationVerdicts};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final verdicts = state.verificationVerdicts
        .map(
          (final line) =>
              RungVerdict.fromJson(jsonDecode(line) as Map<String, dynamic>),
        )
        .toList();
    if (verdicts.isEmpty) {
      return StepResult.failure(
        'verification-report: no rung verdicts recorded — compose '
        'VerifyTarget, not raw steps',
      );
    }
    print('');
    print('🪜 Verification ladder:');
    for (final v in verdicts) {
      print('   $v');
    }
    final failed = verdicts
        .where((final v) => v.status == RungStatus.failed)
        .toList();
    final inconclusive = verdicts
        .where((final v) => v.status == RungStatus.inconclusiveDevice)
        .toList();
    if (failed.isNotEmpty) {
      return StepResult.failure(
        'verification failed at: '
        '${failed.map((final v) => v.rung).join(', ')}',
      );
    }
    if (inconclusive.isNotEmpty) {
      return StepResult.failure(
        'verification INCONCLUSIVE — device/host unhealthy '
        '(${inconclusive.map((final v) => v.detail).join('; ')}). '
        'Fix the device or use a fresh one; results from this state are '
        'not evidence.',
      );
    }
    print('🪜 All ${verdicts.length} rungs passed — the release starts.');
    return StepResult.success();
  }
}
