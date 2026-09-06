import 'dart:io';

import 'package:oka_core/src/oka_run.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('loadOkaYaml — config sources', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('oka_config_src_');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('oka.yaml wins when both oka.yaml and pubspec oka: exist', () async {
      File(p.join(tmp.path, 'oka.yaml')).writeAsStringSync(
        'android:\n  package_name: from.oka.yaml\n',
      );
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(
        'name: demo\noka:\n  android:\n    package_name: from.pubspec\n',
      );
      final config = await loadOkaYaml(tmp.path);
      expect(config.android.packageName, 'from.oka.yaml');
    });

    test('reads a top-level oka: section from pubspec.yaml', () async {
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(
        'name: demo\ndependencies:\n  flutter:\n    sdk: flutter\n'
        'oka:\n  android:\n    package_name: dev.example.pubspec\n'
        '    min_sdk: "24"\n  name: Demo App\n',
      );
      final config = await loadOkaYaml(tmp.path);
      expect(config.android.packageName, 'dev.example.pubspec');
      expect(config.android.minSdk, '24');
      expect(config.name, 'Demo App');
    });

    test('returns empty config when neither source declares oka settings',
        () async {
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
      final config = await loadOkaYaml(tmp.path);
      expect(config.value, isEmpty);
      expect(config.android.packageName, isEmpty);
    });

    test('returns empty config for a bare project directory', () async {
      final config = await loadOkaYaml(tmp.path);
      expect(config.value, isEmpty);
    });
  });
}
