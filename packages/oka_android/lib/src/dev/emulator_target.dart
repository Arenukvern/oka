/// Android emulator lifecycle as a composable target (ADR-0013: platform-
/// scoped tool provisioning + ADR-0015: targets are typed values).
///
/// `EmulatorTarget` boots (idempotently) an AVD so custom pipelines and
/// test flows can compose "make sure an emulator is running" as a step
/// chain instead of shell incantations:
///
/// ```dart
/// Oka(
///   targets: [
///     EmulatorTarget(apiLevel: 34),            // defaults: create + boot
///     // ... or compose with the device flow in a custom target:
///   ],
/// )
/// ```
///
/// Run with `oka run emulator`. The compiled steps provide the
/// [emulatorSerial] artifact — downstream steps (adb install/launch) can
/// consume it as the `-s` serial (multi-device safe).
///
/// Defaults follow the no-surprises law (ADR-0007): create the AVD if
/// missing (non-interactive; a missing system image fails naming the exact
/// `sdkmanager` command), boot headless, reuse an already-running emulator
/// for the same AVD, never wipe user data unless asked.
library;

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:oka_core/oka_core.dart';

import '../android_state.dart';
import '../build/toolchain.dart';
import 'adb_tool.dart';

// -- Pure command construction (scripted-fake testable) ----------------------

/// `avdmanager list avd` (the AVD inventory — `emulator -list-avds` is an
/// emulator-binary flag, NOT an avdmanager one; passing it there is the bug
/// this helper naming exists to prevent).
List<String> avdManagerListArgs() => ['list', 'avd'];

/// `avmmanager create avd -n <name> -k "<image>" [-d <device>]` — `echo no |
/// ` is the caller's job (stdin must never be attached; avdmanager's custom
/// hardware profile prompt defaults to no).
List<String> avdManagerCreateArgs({
  required final String name,
  required final String image,
  final String? deviceProfile,
}) =>
    [
      'create',
      'avd',
      '--force',
      '--name',
      name,
      '--package',
      image,
      if (deviceProfile != null) ...['--device', deviceProfile],
    ];

/// `emulator -avd <name> [flags]`.
List<String> emulatorLaunchArgs({
  required final String name,
  final bool headless = true,
  final bool noSnapshotSave = true,
}) =>
    [
      '-avd',
      name,
      if (headless) ...['-no-window', '-no-audio', '-no-boot-anim'],
      if (noSnapshotSave) '-no-snapshot-save',
    ];

/// Parses `avdmanager list avd` output for the AVD names (`Name: <x>`
/// blocks, ignoring blanks and INFO noise).
List<String> parseAvdManagerNames(final String output) => output
    .split('\n')
    .map((final l) => l.trim())
    .where((final l) => l.startsWith('Name:'))
    .map((final l) => l.substring('Name:'.length).trim())
    .where((final l) => l.isNotEmpty)
    .toList();

/// Extracts the AVD name from `adb -s <serial> emu avd name` output
/// (`<name>\nOK`).
String? parseEmuAvdName(final String output) {
  final lines = output
      .split('\n')
      .map((final l) => l.trim())
      .where((final l) => l.isNotEmpty && l != 'OK')
      .toList();
  return lines.isEmpty ? null : lines.first;
}

/// True when [output] (from `adb shell getprop sys.boot_completed`) means
/// "booted".
bool parseBootCompleted(final String output) =>
    output.trim() == '1';

// -- Target ------------------------------------------------------------------

/// Artifact: the booted emulator's adb serial (`emulator-5554`).
const emulatorSerial = Artifact<String>('emulator-serial');

/// Boots an Android emulator, idempotently (ADR-0013 T2 scope: provisioning
/// + lifecycle wiring; the dev loop composes this — it does not duplicate
/// it).
class EmulatorTarget extends Target {
  const EmulatorTarget({
    this.avdName = 'oka-emulator',
    this.apiLevel = 34,
    this.abi,
    this.imageVariant = 'google_apis',
    this.deviceProfile = 'pixel',
    this.createIfMissing = true,
    this.headless = true,
    this.bootTimeout = const Duration(minutes: 5),
    this.deviceId,
    this.adbPath,
    this.emulatorPath,
    this.avdManagerPath,
    this.toolchain,
    this.stopOnExit = false,
  });

  /// AVD name. Default `oka-emulator` — a dedicated AVD, never a user's
  /// personal one.
  final String avdName;

  /// Android API level of the system image.
  final int apiLevel;

  /// System image ABI. Default: arm64-v8a on ARM hosts, x86_64 otherwise.
  final String? abi;

  /// System image variant (`google_apis`, `default`, `google_apis_playstore`).
  final String imageVariant;

  /// AVD device profile passed to `avdmanager --device`.
  final String? deviceProfile;

  /// Create the AVD when missing (default true). When false, a missing AVD
  /// fails naming the exact `avmmanager` command.
  final bool createIfMissing;

  /// Headless boot (`-no-window -no-audio -no-boot-anim`) — CI/agent default.
  final bool headless;

  /// How long to wait for `sys.boot_completed`.
  final Duration bootTimeout;

  /// Explicit adb serial override (multi-device; `-s`). Null = discover.
  final String? deviceId;

  /// Injectable tool paths (tests / explicit config); null → [toolchain].
  final String? adbPath;
  final String? emulatorPath;
  final String? avdManagerPath;

  /// Injectable toolchain (ADR-0013 T2); null → `state.resolvedToolchain`
  /// → default policy.
  final ResolvedToolchain? toolchain;

  /// Compose [StopEmulatorStep] into the run's teardown (ADR-0018 §2) —
  /// the emulator stops when the run ends, success or failure. Default
  /// false preserves the long-lived dev posture (`oka run emulator` leaves
  /// it up for reuse; the lease records it as owned/borrowed either way).
  /// CI/agent one-shot flows opt in.
  final bool stopOnExit;

  String get _systemImage =>
      'system-images;android-$apiLevel;$imageVariant;${abi ?? defaultAbi()}';

  @override
  String get name => 'emulator';

  @override
  String get description =>
      'Ensure an Android emulator is running (create AVD if missing, boot '
      'headless by default, reuse an already-running instance)';

  @override
  Set<String> get supportedInvocationArgs => const {'device'};

  @override
  EmulatorTarget applyInvocationArgs(final Map<String, String> args) {
    final unknown = args.keys.toSet().difference(supportedInvocationArgs);
    if (unknown.isNotEmpty) {
      throw ArgumentError(
        'target "emulator" does not accept invocation arg(s): '
        '${unknown.join(', ')} — accepted: device=<serial>.',
      );
    }
    final id = args['device'];
    if (id == null || id.trim().isEmpty) return this;
    return EmulatorTarget(
      avdName: avdName,
      apiLevel: apiLevel,
      abi: abi,
      imageVariant: imageVariant,
      deviceProfile: deviceProfile,
      createIfMissing: createIfMissing,
      headless: headless,
      bootTimeout: bootTimeout,
      deviceId: id.trim(),
      adbPath: adbPath,
      emulatorPath: emulatorPath,
      avdManagerPath: avdManagerPath,
      toolchain: toolchain,
      stopOnExit: stopOnExit,
    );
  }

  @override
  List<BuildStep> compile(final BuildContext ctx) => [
        EnsureAvdStep(
          avdName: avdName,
          systemImage: _systemImage,
          deviceProfile: deviceProfile,
          createIfMissing: createIfMissing,
          avdManagerPath: avdManagerPath,
          toolchain: toolchain,
        ),
        BootEmulatorStep(
          avdName: avdName,
          headless: headless,
          bootTimeout: bootTimeout,
          deviceId: deviceId,
          adbPath: adbPath,
          emulatorPath: emulatorPath,
          toolchain: toolchain,
        ),
      ];

  /// ADR-0018 §2: when [stopOnExit] is set, the run ends with
  /// `adb emu kill` on the booted/adopted serial (best-effort, never
  /// masking the run result). Adopted (borrowed) emulators are still
  /// stopped here — the target's own reuse contract makes an explicit
  /// stop-on-exit declaration the owner's intent — while `oka stop`
  /// (lease-based) keeps the borrowed refusal.
  @override
  List<BuildStep> compileTeardown(final BuildContext ctx) =>
      stopOnExit
          ? [StopEmulatorStep(adbPath: adbPath, toolchain: toolchain)]
          : const <BuildStep>[];
}

/// Host-ABI default: arm64-v8a on ARM hosts, x86_64 otherwise.
String defaultAbi() {
  final a = Abi.current();
  final isArm = a == Abi.macosArm64 ||
      a == Abi.linuxArm64 ||
      a == Abi.androidArm64 ||
      a == Abi.iosArm64;
  return isArm ? 'arm64-v8a' : 'x86_64';
}

// -- Steps -------------------------------------------------------------------

/// Resolves a tool path: explicit → state toolchain → default policy.
Future<String> _resolveTool(
  final PipelineState state, {
  required final String tool,
  final String? explicit,
  final ResolvedToolchain? toolchain,
}) async {
  if (explicit != null) return explicit;
  final resolved = toolchain ?? state.resolvedToolchain ?? ResolvedToolchain();
  return (await resolved.require(ToolQuery(tool))).path;
}

/// Ensures the AVD exists (creates it when [createIfMissing]; a missing
/// system image fails closed, naming the exact non-interactive `sdkmanager`
/// command).
class EnsureAvdStep extends BuildStep {
  EnsureAvdStep({
    required this.avdName,
    required this.systemImage,
    this.deviceProfile,
    this.createIfMissing = true,
    this.avdManagerPath,
    this.toolchain,
    final Future<ProcessResult> Function(String, List<String>)? runProcess,
  }) : _runProcess = runProcess ?? _defaultRun;

  final String avdName;
  final String systemImage;
  final String? deviceProfile;
  final bool createIfMissing;
  final String? avdManagerPath;
  final ResolvedToolchain? toolchain;
  final Future<ProcessResult> Function(String, List<String>) _runProcess;

  @override
  String get name => 'ensure-avd';

  Future<ProcessResult> _run(
    final String exe,
    final List<String> args,
  ) =>
      _runProcess(exe, args);

  static Future<ProcessResult> _defaultRun(
    final String exe,
    final List<String> args,
  ) =>
      Process.run(exe, args);

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final String avdManager;
    try {
      avdManager = await _resolveTool(
        state,
        explicit: avdManagerPath,
        toolchain: toolchain,
        tool: 'avdmanager',
      );
    } on ToolchainException {
      return StepResult.failure(
        'avdmanager not found — install cmdline-tools '
        '(`sdkmanager "cmdline-tools;latest"`), or run `oka get android-sdk`.',
      );
    }

    final listed = await _run(avdManager, avdManagerListArgs());
    final avds = parseAvdManagerNames(listed.stdout as String);
    if (avds.contains(avdName)) {
      state['emulator-avd'] = avdName;
      return StepResult.success({'emulator-avd': avdName});
    }
    if (!createIfMissing) {
      return StepResult.failure(
        'AVD "$avdName" does not exist. Create it with:\n'
        '   echo no | avmmanager create avd ${avdManagerCreateArgs(name: avdName, image: systemImage, deviceProfile: deviceProfile).join(' ')}',
      );
    }

    print('🧱 Creating AVD "$avdName" ($systemImage)…');
    final created = await _run(
      avdManager,
      avdManagerCreateArgs(
        name: avdName,
        image: systemImage,
        deviceProfile: deviceProfile,
      ),
    );
    final out = '${created.stdout}${created.stderr}';
    if (created.exitCode != 0 ||
        out.contains('Error:') ||
        out.contains('error:')) {
      final missingImage = out.contains('Could not find') ||
          out.contains('has not been downloaded') ||
          out.contains('Failed to find');
      return StepResult.failure(
        missingImage
            ? 'System image "$systemImage" is not installed. Install it '
                'non-interactively, accepting licenses first:\n'
                '   yes | sdkmanager --licenses\n'
                '   sdkmanager "$systemImage"\n'
                '   (or accept licenses once, then `oka get android-sdk` '
                'provisions through the oka store).'
            : 'avmmanager create avd failed:\n$out',
      );
    }
    state['emulator-avd'] = avdName;
    return StepResult.success({'emulator-avd': avdName});
  }
}

/// Boots the emulator (idempotent: reuses an already-running instance for
/// the same AVD) and waits for `sys.boot_completed`. Provides
/// [emulatorSerial].
class BootEmulatorStep extends BuildStep {
  BootEmulatorStep({
    required this.avdName,
    this.headless = true,
    this.bootTimeout = const Duration(minutes: 5),
    this.pollInterval = const Duration(seconds: 2),
    this.killGrace = const Duration(milliseconds: 1500),
    this.deviceId,
    this.adbPath,
    this.emulatorPath,
    this.toolchain,
    this.liveness,
    this.leaseRegistry,
    this.ownerCmd = 'oka run emulator',
    final Future<ProcessResult> Function(String, List<String>)? runProcess,
    final Future<Process> Function(String, List<String>)? startProcess,
  })  : _runProcess = runProcess ?? Process.run,
        _startProcess = startProcess ?? Process.start;

  final String avdName;
  final bool headless;
  final Duration bootTimeout;

  /// Poll cadence for serial discovery + boot checks (tests shrink this).
  final Duration pollInterval;

  /// Explicit serial (multi-device); null = discover emulator-* serials.
  final String? deviceId;
  final String? adbPath;
  final String? emulatorPath;
  final ResolvedToolchain? toolchain;

  /// How long the spawned emulator gets to exit after the graceful
  /// SIGTERM before the failure paths escalate to SIGKILL (ADR-0018 §1
  /// graceful-first ladder; tests shrink this).
  final Duration killGrace;

  /// Platform liveness/identity/kill seam (ADR-0018 §1); null →
  /// [HostProcessLiveness]. Injectable for scripted-fake tests.
  final ProcessLiveness? liveness;

  /// Lease registry override; null → the standard project location
  /// (`<project>/.oka_cache/processes/`). Injectable for tests.
  final ProcessLeaseRegistry? leaseRegistry;

  /// Recorded in the lease's `owner_cmd` (ADR-0018 §1).
  final String ownerCmd;

  final Future<ProcessResult> Function(String, List<String>) _runProcess;
  final Future<Process> Function(String, List<String>) _startProcess;

  @override
  String get name => 'boot-emulator';

  @override
  Set<Artifact<Object>> get provides => {emulatorSerial};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final String adb;
    final String emulator;
    try {
      adb = await _resolveTool(state, explicit: adbPath, toolchain: toolchain, tool: 'adb');
      emulator =
          await _resolveTool(state, explicit: emulatorPath, toolchain: toolchain, tool: 'emulator');
    } on ToolchainException {
      return StepResult.failure(
        'adb/emulator not found — install platform-tools + emulator '
        '(`sdkmanager "platform-tools" "emulator"`), or `oka get android-sdk`.',
      );
    }

    Future<ProcessResult> runCmd(final List<String> args) =>
        _runProcess(adb, args);

    final deadline = DateTime.now().add(bootTimeout);

    // Idempotent: reuse a running instance for the same AVD.
    final running = await runCmd(adbDevicesArgs());
    final serials = (running.stdout as String)
        .split('\n')
        .map((final l) => l.trim())
        .where((final l) => l.startsWith('emulator-'))
        .map((final l) => l.split(RegExp(r'\s+')).first)
        .toList();
    for (final serial in serials) {
      final avdOut = await runCmd([...adbSerialArgs(serial), 'emu', 'avd', 'name']);
      if (parseEmuAvdName(avdOut.stdout as String) == avdName) {
        print('✅ Emulator for "$avdName" already running ($serial) — reusing.');
        await _adoptLease(serial, ctx);
        state[emulatorSerial.id] = serial;
        return StepResult.success({emulatorSerial.id: serial});
      }
    }

    // Explicit serial override (multi-device): manage THAT serial.
    if (deviceId != null && deviceId!.trim().isNotEmpty) {
      final serial = deviceId!.trim();
      final booted = await _awaitBoot(serial, runCmd, deadline);
      if (booted) {
        print('✅ Emulator booted ($serial).');
        state[emulatorSerial.id] = serial;
        return StepResult.success({emulatorSerial.id: serial});
      }
      return StepResult.failure(
        'Emulator $serial did not finish booting within '
        '${bootTimeout.inSeconds}s (sys.boot_completed never became 1).',
      );
    }

    // Boot.
    print('📲 Booting emulator "$avdName"…');
    // Keep the handle (ADR-0018 problem A): the failure paths below stop
    // exactly the process we spawned instead of leaking it.
    final Process? process = await _spawnSafely(
      emulator,
      emulatorLaunchArgs(name: avdName, headless: headless),
    );
    final String? pidToken;
    if (process != null) {
      // Lease at spawn time (ADR-0018 §1): identity carries the avd; the
      // discovered serial + stop_hint are filled in below.
      pidToken = await _identityToken(process.pid);
      await _upsertLease(spawnLease(process.pid, pidToken), ctx);
    } else {
      pidToken = null;
    }

    // Discover the serial: a fresh boot registers a NEW emulator-* entry —
    // diff against the serials seen before launch.
    final before = serials.toSet();
    String? serial;
    while (DateTime.now().isBefore(deadline)) {
      final listed = await runCmd(adbDevicesArgs());
      final candidates = (listed.stdout as String)
          .split('\n')
          .map((final l) => l.trim())
          .where((final l) => l.startsWith('emulator-'))
          .map((final l) => l.split(RegExp(r'\s+')).first)
          .where((final s) => !before.contains(s))
          .toList();
      if (candidates.isNotEmpty) {
        serial = candidates.first;
        break;
      }
      await Future<void>.delayed(pollInterval);
    }
    if (serial == null) {
      final stopped = await _stopSpawned(process, pidToken, ctx);
      return StepResult.failure(
        'Emulator did not register within ${bootTimeout.inSeconds}s. '
        'Check `$emulator -avd $avdName` output; for CI use a headless boot '
        'and confirm KVM/HVF acceleration is available.'
        '${stopped ? ' The spawned emulator process was stopped.' : ''}',
      );
    }

    if (process != null) {
      // Fill the lease in with the discovered serial + adb stop_hint.
      await _upsertLease(spawnLease(process.pid, pidToken, serial: serial), ctx);
    }

    final booted = await _awaitBoot(serial, runCmd, deadline);
    if (booted) {
      print('✅ Emulator booted ($serial).');
      state[emulatorSerial.id] = serial;
      return StepResult.success({emulatorSerial.id: serial});
    }
    final stopped = await _stopSpawned(process, pidToken, ctx);
    return StepResult.failure(
      'Emulator $serial did not finish booting within '
      '${bootTimeout.inSeconds}s (sys.boot_completed never became 1).'
      '${stopped ? ' The spawned emulator process was stopped.' : ''}',
    );
  }

  /// Polls `sys.boot_completed` until [deadline].
  Future<bool> _awaitBoot(
    final String serial,
    final Future<ProcessResult> Function(List<String>) runCmd,
    final DateTime deadline,
  ) async {
    while (DateTime.now().isBefore(deadline)) {
      final boot = await runCmd([
        ...adbSerialArgs(serial),
        'shell',
        'getprop',
        'sys.boot_completed',
      ]);
      if (parseBootCompleted(boot.stdout as String)) return true;
      await Future<void>.delayed(pollInterval);
    }
    return false;
  }

  // -- Lease recording + identity-verified failure-path kill (ADR-0018) ---

  ProcessLiveness get _host => liveness ?? const HostProcessLiveness();

  /// Lease id for this step's AVD — the ADR §1 shape (`emulator-<avd>`).
  String get _leaseId => 'emulator-$avdName';

  ProcessLeaseRegistry _registryFor(final BuildContext ctx) =>
      leaseRegistry ??
      ProcessLeaseRegistry.forProject(ctx.projectPath, liveness: _host);

  /// The spawned-emulator lease (scope ephemeral, ownership owned, kind
  /// `android-emulator`, identity avd + [serial], stop_hint
  /// `adb [-s serial] emu kill`). [serial] is filled in once discovery
  /// finds the new emulator-* entry.
  @visibleForTesting
  ProcessLease spawnLease(final int pid, final String? pidToken, {final String? serial}) =>
      ProcessLease(
        id: _leaseId,
        pid: pid,
        kind: 'android-emulator',
        identity: {
          'avd': avdName,
          'serial': ?serial,
          processLeasePidTokenKey: ?pidToken,
        },
        scope: LeaseScope.ephemeral,
        ownership: LeaseOwnership.owned,
        ownerCmd: ownerCmd,
        startedAt: DateTime.now().toUtc(),
        stopHint: LeaseStopHint(
          tool: 'adb',
          args: serial == null
              ? ['emu', 'kill']
              : [...adbSerialArgs(serial), 'emu', 'kill'],
        ),
      );

  /// Adopt path (ADR-0018 §3): flip any existing lease for this AVD to
  /// ownership `borrowed`; if none exists, record one as borrowed (pid 0 —
  /// adopted by semantic discovery, `adb emu avd name`). Never kills
  /// anything: teardown stops only owned leases.
  Future<void> _adoptLease(final String serial, final BuildContext ctx) async {
    try {
      final registry = _registryFor(ctx);
      for (final lease in await registry.list()) {
        if (lease.kind == 'android-emulator' && lease.identity['avd'] == avdName) {
          if (lease.ownership == LeaseOwnership.borrowed) return;
          await registry.upsert(
            lease.copyWith(
              identity: {
                ...lease.identity,
                'serial': serial,
              },
              ownership: LeaseOwnership.borrowed,
              stopHint: LeaseStopHint(
                tool: 'adb',
                args: [...adbSerialArgs(serial), 'emu', 'kill'],
              ),
            ),
          );
          return;
        }
      }
      await registry.upsert(
        ProcessLease(
          id: _leaseId,
          pid: 0,
          kind: 'android-emulator',
          identity: {'avd': avdName, 'serial': serial},
          scope: LeaseScope.ephemeral,
          ownership: LeaseOwnership.borrowed,
          ownerCmd: ownerCmd,
          startedAt: DateTime.now().toUtc(),
          stopHint: LeaseStopHint(
            tool: 'adb',
            args: [...adbSerialArgs(serial), 'emu', 'kill'],
          ),
        ),
      );
    } on Object catch (e) {
      // Leases are advisory: a failed record must never fail a build.
      print('⚠️ Could not record borrowed emulator lease: $e');
    }
  }

  /// Identity-verified, graceful-first stop of the spawned emulator
  /// process (ADR-0018 §1 identity-over-pid) plus lease cleanup. Never
  /// signals an unverifiable pid: a recycled pid belongs to an innocent
  /// process, and a token we could not verify is a report, not a guess.
  Future<bool> _stopSpawned(
    final Process? process,
    final String? pidToken,
    final BuildContext ctx,
  ) async {
    if (process == null) return true; // nothing spawned, nothing to clean
    final verified = await verifyKillIdentity(_host, process.pid, pidToken);
    if (verified == KillIdentity.recycled) {
      // The record's pid belongs to someone else now — the *record* is
      // provably stale; drop it, but never signal the recycled pid.
      await _deleteLease(ctx);
      print('⚠️ Emulator pid ${process.pid} was recycled — not signaled '
          '(pid-reuse guard, ADR-0018 §1); lease dropped as stale.');
      return false;
    }
    if (verified == KillIdentity.unknown) {
      // Identity unobtainable: report-never-guess. Keep the lease so the
      // reconcile sweep (L2) can surface it.
      print('⚠️ Emulator pid ${process.pid} identity unverified — not '
          'signaled (pid-reuse guard, ADR-0018 §1); lease kept for '
          'reconciliation.');
      return false;
    }
    process.kill(); // SIGTERM — graceful-first.
    await Future<void>.delayed(killGrace);
    if (await _isAlive(process.pid)) {
      // Last rung of the ladder: force.
      Process.killPid(process.pid, ProcessSignal.sigkill);
    }
    await _deleteLease(ctx);
    print('🛑 Spawned emulator process (pid ${process.pid}) stopped.');
    return true;
  }

  Future<void> _upsertLease(final ProcessLease lease, final BuildContext ctx) async {
    try {
      await _registryFor(ctx).upsert(lease);
    } on Object catch (e) {
      // Leases are advisory: a failed record must never fail a build.
      print('⚠️ Could not write emulator lease: $e');
    }
  }

  Future<void> _deleteLease(final BuildContext ctx) async {
    try {
      await _registryFor(ctx).delete(_leaseId);
    } on Object {
      // Advisory; a leftover record is reconciled later.
    }
  }

  Future<String?> _identityToken(final int pid) async {
    try {
      return await _host.identityToken(pid);
    } on Object {
      return null;
    }
  }

  Future<bool> _isAlive(final int pid) async {
    try {
      return await _host.isAlive(pid);
    } on Object {
      return false;
    }
  }

  /// Spawns the emulator keeping the [Process] handle (ADR-0018 problem
  /// A); spawn errors stay swallowed (historical posture) — serial
  /// discovery below fails with its own actionable message either way.
  Future<Process?> _spawnSafely(
    final String emulator,
    final List<String> args,
  ) async {
    try {
      return await _startProcess(emulator, args);
    } on Object {
      return null;
    }
  }
}

/// Stops a booted emulator (`adb -s <serial> emu kill`) — compose into
/// teardown targets; requires [emulatorSerial] (or an explicit serial).
class StopEmulatorStep extends BuildStep {
  StopEmulatorStep({this.serial, this.adbPath, this.toolchain});

  /// Explicit serial; null → the [emulatorSerial] artifact from upstream.
  final String? serial;
  final String? adbPath;
  final ResolvedToolchain? toolchain;

  @override
  String get name => 'stop-emulator';

  @override
  Set<Artifact<Object>> get requires => serial == null ? {emulatorSerial} : {};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final target =
        serial ?? state[emulatorSerial.id] as String?;
    if (target == null || target.isEmpty) {
      return StepResult.failure(
        'No emulator serial to stop — run the emulator target first or '
        'declare StopEmulatorStep(serial: ...).',
      );
    }
    final adb = await _resolveTool(
      state,
      explicit: adbPath,
      toolchain: toolchain,
      tool: 'adb',
    );
    await Process.run(adb, [...adbSerialArgs(target), 'emu', 'kill']);
    print('🛑 Emulator $target stopped.');
    return StepResult.success();
  }
}
