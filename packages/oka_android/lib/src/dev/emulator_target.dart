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

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

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
    this.deviceId,
    this.adbPath,
    this.emulatorPath,
    this.toolchain,
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
    final start = _startProcess(
      emulator,
      emulatorLaunchArgs(name: avdName, headless: headless),
    );
    // The emulator process runs for the emulator's lifetime — never awaited.
    unawaited(start.then((_) {}, onError: (_) {}));

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
      return StepResult.failure(
        'Emulator did not register within ${bootTimeout.inSeconds}s. '
        'Check `$emulator -avd $avdName` output; for CI use a headless boot '
        'and confirm KVM/HVF acceleration is available.',
      );
    }

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
