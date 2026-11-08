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
          '${attachDdsPortWhenOkaOwnsHostForward}',
        ],
      );
    });
  });
}
