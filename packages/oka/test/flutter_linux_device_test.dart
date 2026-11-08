import 'package:oka/src/doctor/flutter_linux_device.dart';
import 'package:test/test.dart';

void main() {
  test('accepts linux desktop device by targetPlatform', () {
    const raw = '''
[
  {"name": "Linux", "id": "linux", "targetPlatform": "linux", "emulator": false}
]
''';
    final p = FlutterLinuxDeviceParse.fromMachineStdout(raw);
    expect(p.error, isNull);
    expect(p.hasLinuxDesktop, isTrue);
    expect(p.linuxDesktopDeviceIds, ['linux']);
  });

  test('rejects android device named linux-phone (name substring trap)', () {
    const raw = '''
[
  {"name": "linux-phone", "id": "emulator-5554", "targetPlatform": "android", "emulator": true}
]
''';
    final p = FlutterLinuxDeviceParse.fromMachineStdout(raw);
    expect(p.error, isNull);
    expect(p.hasLinuxDesktop, isFalse);
  });

  test('rejects malformed JSON', () {
    final p = FlutterLinuxDeviceParse.fromMachineStdout('not json');
    expect(p.error, contains('malformed JSON'));
  });

  test('rejects non-array JSON', () {
    final p = FlutterLinuxDeviceParse.fromMachineStdout('{}');
    expect(p.error, contains('expected JSON array'));
  });
}
