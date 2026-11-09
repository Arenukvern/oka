import 'package:oka/src/cli/dev_android_attach.dart';
import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  test('buildDevAndroidAttachArgv threads host forward port to attach spawn', () {
    const prepared = DevLaunchPrepared(
      apkPath: '/tmp/a.apk',
      vmServiceUri: 'ws://127.0.0.1:36605/secret=/ws',
      vmServiceLocalPort: 36605,
      vmServiceDevicePort: 43239,
      vmServiceDeviceDebugUrl: 'http://device:43239/secret=/',
    );
    final argv = buildDevAndroidAttachArgv(
      deviceId: 'emulator-5554',
      prepared: prepared,
    );
    expect(argv, contains('--host-vmservice-port'));
    final idx = argv.indexOf('--host-vmservice-port');
    expect(argv[idx + 1], '36605');
    expect(argv, contains('--device-vmservice-port'));
  });
}
