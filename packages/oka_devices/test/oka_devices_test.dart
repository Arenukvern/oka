import 'package:oka_android/oka_android.dart'
    hide LeaseOwnership, attachDdsPortWhenOkaOwnsHostForward;
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
    app: AppSpec(projectPath: '/proj'),
    ports: ports ?? PortPlan.okaOwnsHostForward(),
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

  group('PortPlan DDS when oka owns host forward', () {
    test('validate rejects OkaAllocated dds with oka-owned host', () {
      const plan = PortPlan(
        hostVmService: OkaAllocated(),
        dds: OkaAllocated(),
        adbForward: Delegated(),
        control: OkaAllocated(),
      );
      expect(
        plan.validate().single,
        contains('dds must be FixedPort($attachDdsPortWhenOkaOwnsHostForward)'),
      );
    });

    test('plan emits --dds-port 0 for oka-owned host forward default', () {
      final spec = _minimalRun();
      expect(spec.plan(), [
        'attach',
        '--machine',
        '-d',
        'emulator-5554',
        '--dds-port',
        '$attachDdsPortWhenOkaOwnsHostForward',
      ]);
    });

    test('host and dds port 0 do not conflict', () {
      const plan = PortPlan(
        hostVmService: FixedPort(8181),
        dds: FixedPort(0),
        adbForward: Delegated(),
        control: OkaAllocated(),
      );
      expect(plan.validate(), isEmpty);
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
        app: AppSpec(projectPath: ''),
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
      final problems = _minimalRun(ownership: LeaseOwnership.borrowed)
          .validate();
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
      final problems = plan.validate();
      expect(problems.length, greaterThanOrEqualTo(2));
      expect(problems, anyElement(contains('must not use the same fixed port')));
      expect(problems, anyElement(contains('dds must be FixedPort(0)')));
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
    test('equals flutterAttachMachineArgs with host forward and dds 0', () {
      final spec = _minimalRun(
        ports: const PortPlan(
          hostVmService: FixedPort(8181),
          dds: FixedPort(0),
          adbForward: Delegated(),
          control: OkaAllocated(),
        ),
      );
      expect(
        spec.plan(),
        flutterAttachMachineArgs(
          deviceId: spec.attachDeviceId,
          hostVmServicePort: 8181,
          ddsPort: attachDdsPortWhenOkaOwnsHostForward,
        ),
      );
    });

    test('rejects non-zero dds when oka owns host forward', () {
      const plan = PortPlan(
        hostVmService: FixedPort(8181),
        dds: FixedPort(8182),
        adbForward: Delegated(),
        control: OkaAllocated(),
      );
      expect(plan.validate().single, contains('dds must be FixedPort(0)'));
    });
  });

  group('PhysicalDeviceSpec', () {
    test('is always borrowed', () {
      final physical = PhysicalDeviceSpec(id: 'phone', serial: 'ABC123');
      expect(physical.ownership, LeaseOwnership.borrowed);
      expect(physical.adbSerial, 'ABC123');
      expect(physical.flutterDeviceId, 'ABC123');
    });
  });

  group('AppSpec', () {
    test('defines map is unmodifiable', () {
      final spec = AppSpec(projectPath: '/p', defines: const {'A': '1'});
      expect(() => spec.defines['B'] = '2', throwsUnsupportedError);
    });
  });
}
