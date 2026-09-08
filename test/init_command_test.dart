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

  test('default init scaffolds a full-Dart pipeline (no oka.yaml)',
      () async {
    await InitCommand().run([]);

    // ADR-0010: typed entrypoint at the discovery convention; no YAML.
    final entry = File(p.join(tmp.path, 'tool', 'oka_pipeline.dart'));
    expect(entry.existsSync(), isTrue);
    expect(File(p.join(tmp.path, 'oka.yaml')).existsSync(), isFalse);

    final content = entry.readAsStringSync();
    expect(content, contains("name: 'my_app'"));
    expect(content, contains("packageName: 'com.example.my_app'"));
    expect(content, contains('versionCode: 7')); // from pubspec 2.3.4+7
    expect(content, contains("versionName: '2.3.4+7'"));
    expect(content, contains('AndroidPipeline.defaultSteps'));
  });

  test('--yaml opts into the legacy YAML-first scaffold', () async {
    await InitCommand().run(['--yaml']);

    final file = File(p.join(tmp.path, 'oka.yaml'));
    expect(file.existsSync(), isTrue);
    expect(File(p.join(tmp.path, 'tool', 'oka_pipeline.dart')).existsSync(),
        isFalse);
    final content = file.readAsStringSync();

    // ADR-0006/0010: commented pipeline.dart_entrypoint example + pointer to
    // the full-Dart conversion.
    expect(content, contains('dart_entrypoint'));
    expect(content, contains('tool/oka_pipeline.dart'));
    expect(
      content,
      contains('#   dart_entrypoint: tool/oka_pipeline.dart'),
    );

    // The scaffold stays commented out — no active pipeline key.
    final parsed = loadYaml(content) as Map;
    expect(parsed.containsKey('pipeline'), isFalse);

    // Base scaffold is valid and mirrors the project.
    expect(parsed['name'], 'my_app');
    expect(parsed['version'], '2.3.4+7');
    expect((parsed['android'] as Map)['package_name'], 'com.example.my_app');
  });

  test('--yaml scaffold preserves the rest of the generated config', () async {
    await InitCommand().run(['--yaml']);
    final parsed = loadYaml(File(p.join(tmp.path, 'oka.yaml')).readAsStringSync()) as Map;
    final android = parsed['android'] as Map;
    expect(android['min_sdk']?.toString(), '21');
    expect(android['abis'], contains('arm64-v8a'));
    // `dependencies:` with an empty list parses as null in YAML.
    expect(parsed['dependencies'] ?? <dynamic>[], isEmpty);
  });

  test('--from-yaml converts oka.yaml into a typed Dart entrypoint', () async {
    await File(p.join(tmp.path, 'oka.yaml')).writeAsString('''
name: my_app
version: 2.3.4+7
android:
  package_name: dev.xs.mine
  min_sdk: 23
  version_code: 51
  version_name: 3.22.0
  abis: [arm64-v8a]
pipeline:
  extra_deps:
    - "com.squareup.okhttp3:okhttp:4.12.0"
''');
    await InitCommand().run(['--from-yaml']);

    final code = File(p.join(tmp.path, 'tool', 'oka_pipeline.dart'));
    expect(code.existsSync(), isTrue);
    final content = code.readAsStringSync();
    expect(content, contains("name: 'my_app'"));
    expect(content, contains("packageName: 'dev.xs.mine'"));
    expect(content, contains("minSdk: '23'"));
    expect(content, contains('versionCode: 51'));
    expect(content, contains("versionName: '3.22.0'"));
    expect(content, contains("extraDeps: ['com.squareup.okhttp3:okhttp:4.12.0']"));
    expect(content, contains('AndroidPipeline.defaultSteps'));
    // Full syntax correctness is covered by the live example migration and
    // adr0010_typed_config_test; a bare temp project cannot resolve the
    // oka package URIs, so analyzer output here would be uri_does_not_exist.
  });

  test('--dart scaffolds a full-Dart entrypoint without oka.yaml', () async {
    await InitCommand().run(['--dart']);
    final entry = File(p.join(tmp.path, 'tool', 'oka_pipeline.dart'));
    expect(entry.existsSync(), isTrue);
    expect(File(p.join(tmp.path, 'oka.yaml')).existsSync(), isFalse);
    expect(entry.readAsStringSync(), contains("packageName: 'com.example.my_app'"));
  });
}
