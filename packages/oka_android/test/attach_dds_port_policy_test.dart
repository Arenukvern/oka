import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  group('attach DDS vs host forward (Flutter 3.47+)', () {
    test('host forward implies explicit --dds-port', () {
      final argv = flutterAttachMachineArgs(
        deviceId: 'emulator-5554',
        deviceVmServicePort: 43239,
        hostVmServicePort: 36605,
      );
      expect(
        argv,
        [
          'attach',
          '--machine',
          '-d',
          'emulator-5554',
          '--device-vmservice-port',
          '43239',
          '--host-vmservice-port',
          '36605',
          '--dds-port',
          '$attachDdsPortWhenOkaOwnsHostForward',
        ],
      );
    });

    test('no host port omits --dds-port', () {
      final argv = flutterAttachMachineArgs(
        deviceId: 'emu',
        deviceVmServicePort: 43239,
      );
      expect(argv, isNot(contains('--dds-port')));
    });

    test('explicit dds override is forwarded', () {
      final argv = flutterAttachMachineArgs(
        deviceId: 'emu',
        hostVmServicePort: 36605,
        ddsPort: 39123,
      );
      expect(argv, containsAll(['--dds-port', '39123']));
    });
  });
}
