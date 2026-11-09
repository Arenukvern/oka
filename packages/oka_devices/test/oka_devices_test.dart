import 'package:oka_android/oka_android.dart' hide LeaseOwnership;
import 'package:oka_devices/oka_devices.dart';
import 'package:test/test.dart';

EmulatorSpec _emulator({
  int consolePort = 5554,
  Display display = const Headless(),
}) => EmulatorSpec(
  id: 'emu',
  avd: const AvdSpec(name: 'oka-emulator'),
  consolePort: consolePort,
  display: display,
);

RunSpec _minimalRun({
  DeviceSpec? device,
  PortPlan? ports,
  LeaseOwnership ownership = LeaseOwnership.owned,
  StartMode startMode = StartMode.start,
}) {
  final emu =
      device ??
      EmulatorSpec(
        id: 'emu',
        avd: const AvdSpec(name: 'oka-emulator'),
        consolePort: 5554,
        ownership: ownership,
        startMode: startMode,
      );
  return RunSpec(
    device: emu,
    app: const AppSpec(projectPath: '/proj'),
    ports:
        ports ??
        const PortPlan(
          hostVmService: OkaAllocated(),
          dds: OkaAllocated(),
          adbForward: Delegated(),
          control: OkaAllocated(),
        ),
  );
}

void main() {
  group('EmulatorSpec', () {
    test('serial is emulator-<consolePort>', () {
      expect(_emulator().serial, 'emulator-5554');
      expect(_emulator(consolePort: 5560).serial, 'emulator-5560');
    });

    test('two console ports yield distinct serials', () {
      final a = _emulator();
      final b = _emulator(consolePort: 5556);
      expect(a.serial, isNot(b.serial));
    });

    test('argv golden: Headless matches EmulatorTarget headless bundle', () {
      expect(_emulator().emulatorArgv(), [
        '-avd',
        'oka-emulator',
        '-port',
        '5554',
        '-gpu',
        'swiftshader_indirect',
        '-no-window',
        '-no-audio',
        '-no-boot-anim',
        '-no-snapshot-save',
      ]);
    });

    test('argv golden: Windowed omits headless flags', () {
      expect(_emulator(display: const Windowed()).emulatorArgv(), [
        '-avd',
        'oka-emulator',
        '-port',
        '5554',
        '-gpu',
        'swiftshader_indirect',
        '-no-snapshot-save',
      ]);
    });
  });

  group('enum .name values (UA round-trip)', () {
    test('LeaseOwnership', () {
      expect(LeaseOwnership.owned.name, 'owned');
      expect(LeaseOwnership.borrowed.name, 'borrowed');
    });

    test('StartMode', () {
      expect(StartMode.start.name, 'start');
      expect(StartMode.attach.name, 'attach');
    });
  });

  group('RunSpec.validate collects every violation', () {
    test('multi-error spec returns all problems at once', () {
      final spec = RunSpec(
        device: EmulatorSpec(
          id: '',
          avd: const AvdSpec(name: ''),
          consolePort: 5555,
          ownership: LeaseOwnership.borrowed,
        ),
        app: const AppSpec(projectPath: ''),
        ports: const PortPlan(
          hostVmService: FixedPort(9100),
          dds: FixedPort(9100),
          adbForward: Delegated(),
          control: Delegated(),
        ),
      );

      final problems = spec.validate();
      expect(problems.length, greaterThan(1));
      expect(problems, contains(startsWith('device id must not be empty')));
      expect(problems, anyElement(contains('avd.name must not be empty')));
      expect(problems, anyElement(contains('consolePort must be even')));
      expect(problems, anyElement(contains('borrowed ownership requires')));
      expect(
        problems,
        anyElement(contains('app.projectPath must not be empty')),
      );
      expect(
        problems,
        anyElement(contains('hostVmService and dds must not use the same')),
      );
      expect(
        problems,
        anyElement(contains('Delegated is only valid for ports.adbForward')),
      );
    });

    test('borrowed + start fails', () {
      final problems = _minimalRun(
        ownership: LeaseOwnership.borrowed,
      ).validate();
      expect(problems, hasLength(1));
      expect(problems.single, contains('borrowed ownership requires'));
    });
  });

  group('PortPlan', () {
    test('rejects identical fixed hostVmService and dds ports', () {
      const plan = PortPlan(
        hostVmService: FixedPort(8181),
        dds: FixedPort(8181),
        adbForward: Delegated(),
        control: OkaAllocated(),
      );
      expect(
        plan.validate().single,
        contains('must not use the same fixed port'),
      );
    });
  });

  group('ensureValid', () {
    test('throws SpecViolationException listing all violations', () {
      expect(
        () => _minimalRun(ownership: LeaseOwnership.borrowed).ensureValid(),
        throwsA(
          isA<SpecViolationException>().having(
            (e) => e.violations.length,
            'violation count',
            1,
          ),
        ),
      );
    });
  });

  group('RunSpec.plan vs flutterAttachMachineArgs', () {
    test('attach prefix agrees with daemon_adapter', () {
      final spec = _minimalRun();
      final planned = spec.plan();
      final expected = flutterAttachMachineArgs(deviceId: spec.attachDeviceId);
      expect(planned.sublist(0, expected.length), expected);
    });

    test('fixed ports append flutter flags', () {
      final spec = _minimalRun(
        ports: const PortPlan(
          hostVmService: FixedPort(8181),
          dds: FixedPort(8182),
          adbForward: Delegated(),
          control: OkaAllocated(),
        ),
      );
      expect(spec.plan(), [
        'attach',
        '--machine',
        '-d',
        'emulator-5554',
        '--host-vmservice-port=8181',
        '--dds-port=8182',
      ]);
    });
  });

  group('PhysicalDeviceSpec', () {
    test('is always borrowed', () {
      final physical = PhysicalDeviceSpec(id: 'phone', serial: 'ABC123');
      expect(physical.ownership, LeaseOwnership.borrowed);
      expect(physical.adbSerial, 'ABC123');
    });
  });
}
