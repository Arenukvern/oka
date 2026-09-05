import 'dart:io';

import 'package:oka/src/cli/init_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory tmp;
  late Directory previousCwd;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('oka-init-');
    previousCwd = Directory.current;
    Directory.current = tmp.path;
    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(
      'name: my_app\nversion: 2.3.4+7\n',
    );
  });

  tearDown(() {
    Directory.current = previousCwd;
    tmp.deleteSync(recursive: true);
  });

  test('generates oka.yaml scaffold with commented dart_entrypoint example',
      () async {
    // No android/app/build.gradle → default (non-AI) config path.
    await InitCommand().run([]);

    final file = File(p.join(tmp.path, 'oka.yaml'));
    expect(file.existsSync(), isTrue);
    final content = file.readAsStringSync();

    // ADR-0006: commented pipeline.dart_entrypoint example + pointer to the
    // custom-pipeline composition example.
    expect(content, contains('dart_entrypoint'));
    expect(content, contains('custom_pipeline.dart'));
    expect(
      content,
      contains('#   dart_entrypoint: bin/oka_pipeline.dart'),
    );

    // The scaffold stays commented out — no active pipeline key.
    final parsed = loadYaml(content) as Map;
    expect(parsed.containsKey('pipeline'), isFalse);

    // Base scaffold is valid and mirrors the project.
    expect(parsed['name'], 'my_app');
    expect(parsed['version'], '2.3.4+7');
    expect((parsed['android'] as Map)['package_name'], 'com.example.my_app');
  });

  test('scaffold preserves the rest of the generated config', () async {
    await InitCommand().run([]);
    final parsed = loadYaml(File(p.join(tmp.path, 'oka.yaml')).readAsStringSync()) as Map;
    final android = parsed['android'] as Map;
    expect(android['min_sdk']?.toString(), '21');
    expect(android['abis'], contains('arm64-v8a'));
    // `dependencies:` with an empty list parses as null in YAML.
    expect(parsed['dependencies'] ?? <dynamic>[], isEmpty);
  });
}
