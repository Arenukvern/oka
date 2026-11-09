/// Device declarations for a dev run.
library;

import 'avd_spec.dart';
import 'display.dart';
import 'session_enums.dart';
import 'spec_violation.dart';

/// Stable id for this device slot in a composition graph.
sealed class DeviceSpec with TypedSpec {
  const DeviceSpec({
    required this.id,
    required this.ownership,
    required this.startMode,
  });

  final String id;
  final LeaseOwnership ownership;
  final StartMode startMode;

  /// adb serial used by attach and adb `-s`.
  String get adbSerial;

  List<String> validateOwnershipStart() {
    if (ownership == LeaseOwnership.borrowed && startMode == StartMode.start) {
      return ['$id: borrowed ownership requires startMode attach, not start'];
    }
    return const [];
  }

  List<String> validateId() {
    if (id.trim().isEmpty) {
      return ['device id must not be empty'];
    }
    return const [];
  }
}

/// Android emulator — serial is known from [consolePort] before boot.
final class EmulatorSpec extends DeviceSpec {
  EmulatorSpec({
    required super.id,
    required this.avd,
    required this.consolePort,
    super.ownership = LeaseOwnership.owned,
    super.startMode = StartMode.start,
    this.gpu = 'swiftshader_indirect',
    this.display = const Headless(),
    this.noSnapshotSave = true,
  });

  final AvdSpec avd;
  final int consolePort;
  final String gpu;
  final Display display;

  /// Matches [emulatorLaunchArgs] default in `emulator_target.dart`.
  final bool noSnapshotSave;

  /// `emulator-<consolePort>` — declared before boot (no adb diff).
  String get serial => 'emulator-$consolePort';

  @override
  String get adbSerial => serial;

  /// Pure `emulator` argv — flag names match `emulatorLaunchArgs`.
  List<String> emulatorArgv() {
    final headless = display is Headless;
    return [
      '-avd',
      avd.name,
      '-port',
      '$consolePort',
      '-gpu',
      gpu,
      if (headless) ...const ['-no-window', '-no-audio', '-no-boot-anim'],
      if (noSnapshotSave) '-no-snapshot-save',
    ];
  }

  @override
  List<String> validate() => [
    ...validateId(),
    ...avd.validate(),
    ...validateConsolePort(),
    ...validateGpu(),
    ...validateDisplay(),
    ...validateOwnershipStart(),
  ];

  List<String> validateConsolePort() {
    final problems = <String>[];
    if (consolePort < 5554 || consolePort > 5682) {
      problems.add('$id: consolePort must be 5554..5682 (got $consolePort)');
    }
    if (consolePort.isOdd) {
      problems.add('$id: consolePort must be even (got $consolePort)');
    }
    return problems;
  }

  List<String> validateGpu() =>
      gpu.trim().isEmpty ? ['$id: gpu must not be empty'] : const [];

  List<String> validateDisplay() => switch (display) {
    VirtualX11(:final displayNumber, :final geometry) => [
      if (displayNumber < 0) '$id: VirtualX11 displayNumber must be >= 0',
      ...geometry.validate(prefix: '$id.display.geometry'),
    ],
    Windowed() || Headless() => const <String>[],
  };
}

/// USB/emulator serial for a physical Android device — always borrowed.
final class PhysicalDeviceSpec extends DeviceSpec {
  PhysicalDeviceSpec({
    required super.id,
    required this.serial,
    super.startMode = StartMode.attach,
  }) : super(ownership: LeaseOwnership.borrowed);

  final String serial;

  @override
  String get adbSerial => serial;

  @override
  List<String> validate() => [
    ...validateId(),
    ...validateSerial(),
    ...validateBorrowedPosture(),
    ...validateOwnershipStart(),
  ];

  List<String> validateSerial() {
    if (serial.trim().isEmpty) {
      return ['$id: serial must not be empty'];
    }
    return const [];
  }

  List<String> validateBorrowedPosture() {
    if (ownership != LeaseOwnership.borrowed) {
      return ['$id: physical devices are always borrowed'];
    }
    return const [];
  }
}
