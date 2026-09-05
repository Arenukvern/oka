import 'dart:io';

import 'package:oka_android/src/auto_resolve.dart';
import 'package:oka_android/src/build/gradle_dep_parser.dart';
import 'package:test/test.dart';

/// Regression corpus from real pub-cache plugins (ADR-0007): every fixture
/// here is a production gradle file that broke a real build once.
void main() {
  group('gradle fixture corpus', () {
    late String dir;

    setUp(() {
      dir = '${Directory.current.path}/test/fixtures/gradle';
    });

    test('mobile_scanner: conditionals + camera deps parse', () {
      final text = File('$dir/mobile_scanner.gradle').readAsStringSync();
      final deps = parseGradleDependencies(text)
          .map((d) => d.coordinate)
          .toSet();
      expect(deps, contains('com.google.mlkit:barcode-scanning:17.3.0'));
      expect(
        deps,
        contains('com.google.android.gms:play-services-mlkit-barcode-scanning:18.3.1'),
      );
      expect(deps, contains('androidx.camera:camera-lifecycle:1.6.1'));
      expect(deps, contains('org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0'));
    });

    test('file_picker (kts add()): tika-core parses', () {
      final text = File('$dir/file_picker.gradle.kts').readAsStringSync();
      final deps = parseGradleDependencies(text)
          .map((d) => d.coordinate)
          .toSet();
      expect(deps, contains('org.apache.tika:tika-core:3.3.0'));
      expect(deps, contains('androidx.core:core-ktx:1.18.0'));
    });

    test('rustore_billing_api (kts): vendor repo URL + SDK coord parse', () {
      final text = File('$dir/rustore_billing_api.gradle.kts')
          .readAsStringSync();
      final deps = parseGradleDependencies(text)
          .map((d) => d.coordinate)
          .toSet();
      expect(deps, contains('ru.rustore.sdk:billingclient:10.1.0'));
      final repos = parseMavenRepositoryUrls(text);
      expect(
        repos.any((u) => u.contains('artifactory-external.vkpartner.ru')),
        isTrue,
      );
    });
  });

  group('ADR-0007 auto-resolve', () {
    test('detectRequiredJavaLevel finds VERSION_17 in gradle text', () {
      final f = File(
        '${Directory.systemTemp.createTempSync('oka_jv').path}/build.gradle',
      )..writeAsStringSync(
          'compileOptions {\n'
          '  sourceCompatibility JavaVersion.VERSION_17\n'
          '}\n',
        );
      expect(detectRequiredJavaLevel([f.path]), 17);
    });

    test('resolveAndroidVersion falls back to pubspec x.y.z+nn', () {
      final dir = Directory.systemTemp.createTempSync('oka_ver');
      File('${dir.path}/pubspec.yaml')
          .writeAsStringSync('name: demo\nversion: 3.22.0+51\n');
      final r = resolveAndroidVersion(
        dir.path,
        configVersionCode: 0,
        configVersionName: '',
      );
      expect(r.versionCode, 51);
      expect(r.versionName, '3.22.0');
      // Explicit config wins.
      final r2 = resolveAndroidVersion(
        dir.path,
        configVersionCode: 7,
        configVersionName: '7.0.0',
      );
      expect(r2.versionCode, 7);
      expect(r2.versionName, '7.0.0');
    });

    test('devDependencyNames reads dev_dependencies block', () {
      final dir = Directory.systemTemp.createTempSync('oka_dev');
      File('${dir.path}/pubspec.yaml').writeAsStringSync(
        'name: demo\n'
        'dependencies:\n'
        '  flutter: {sdk: flutter}\n'
        'dev_dependencies:\n'
        '  integration_test: {sdk: flutter}\n'
        '  flutter_lints: ^5.0.0\n',
      );
      final names = devDependencyNames(dir.path);
      expect(names, contains('integration_test'));
      expect(names, isNot(contains('flutter')));
    });
  });
}
