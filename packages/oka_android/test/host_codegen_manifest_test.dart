import 'package:oka_android/oka_android.dart';
import 'package:test/test.dart';

void main() {
  test('applicationElements render verbatim under <application>', () {
    final xml = generateAndroidManifestFromSpec(
      packageName: 'com.example.app',
      label: 'App',
      minSdk: '21',
      targetSdk: '34',
      spec: const ManifestSpec(
        applicationElements: [
          // ignore: no_adjacent_strings_in_list
          '<service android:name=".TrackingForegroundService"\n'
              'android:exported="false" android:foregroundServiceType="camera" />',
        ],
      ),
    );

    expect(xml, contains('android:name=".TrackingForegroundService"'));
    expect(xml, contains('android:foregroundServiceType="camera"'));
    // Must land inside <application>, before its closing tag.
    final applicationStart = xml.indexOf('<application');
    final serviceStart = xml.indexOf('<service');
    final applicationEnd = xml.indexOf('</application>');
    expect(serviceStart, greaterThan(applicationStart));
    expect(serviceStart, lessThan(applicationEnd));
  });

  test('empty applicationElements emit no placeholder line', () {
    final xml = generateAndroidManifestFromSpec(
      packageName: 'com.example.app',
      label: 'App',
      minSdk: '21',
      targetSdk: '34',
    );
    expect(xml, isNot(contains('<service')));
  });
}
