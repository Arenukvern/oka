import 'dart:convert';
import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

void main() {
  group('ADR-0010: AndroidBuild / FlutterBuild typed config', () {
    test('toConfigMap emits only explicitly set fields, yaml-shaped', () {
      final map = const AndroidBuild(
        packageName: 'com.example.app',
        minSdk: '23',
        abis: ['arm64-v8a'],
      ).toConfigMap();
      expect(map, {
        'package_name': 'com.example.app',
        'min_sdk': '23',
        'abis': ['arm64-v8a'],
      });
      // Unset fields are absent, never empty-string defaults.
      expect(map.containsKey('compile_sdk'), isFalse);
      expect(map.containsKey('version_code'), isFalse);
    });

    test('FlutterBuild toConfigMap emits the flutter: section shape', () {
      final map = const FlutterBuild(
        entrypoint: 'lib/main_prod.dart',
        treeShakeIcons: true,
      ).toConfigMap();
      expect(map, {'entrypoint': 'lib/main_prod.dart', 'tree_shake_icons': true});
    });

    test('copyWith overrides only the given fields', () {
      const base = AndroidBuild(packageName: 'a.b', minSdk: '21');
      final changed = base.copyWith(minSdk: '24');
      expect(changed.packageName, 'a.b');
      expect(changed.minSdk, '24');
    });
  });

  group('ADR-0010: config precedence (dart config over oka.yaml)', () {
    test('mergeConfigMaps: override wins, base-only keys preserved, deep merge',
        () {
      final merged = mergeConfigMaps({
        'name': 'from_yaml',
        'android': {
          'package_name': 'yaml.pkg',
          'min_sdk': '21',
        },
        'flutter': {'entrypoint': 'lib/main.dart'},
      }, {
        'android': {
          'min_sdk': '24',
          'abis': ['arm64-v8a'],
        },
      });
      expect(merged['name'], 'from_yaml');
      expect(merged['android'], {
        'package_name': 'yaml.pkg',
        'min_sdk': '24',
        'abis': ['arm64-v8a'],
      });
      expect((merged['flutter'] as Map)['entrypoint'], 'lib/main.dart');
    });

    test('AndroidPipeline.configOverrides materializes android:/flutter:/name',
        () {
      const pipeline = AndroidPipeline(
        config: AndroidBuild(name: 'example', packageName: 'com.ex'),
        flutterConfig: FlutterBuild(entrypoint: 'lib/main.dart'),
      );
      final overrides = pipeline.configOverrides;
      expect(overrides['name'], 'example');
      expect((overrides['android'] as Map)['package_name'], 'com.ex');
      expect((overrides['flutter'] as Map)['entrypoint'], 'lib/main.dart');
    });

    test('default AndroidPipeline has empty overrides (yaml-only unaffected)',
        () {
      expect(const AndroidPipeline().configOverrides, isEmpty);
      expect(const AndroidPipeline().config, isNull);
    });

    test('okaRun applies typed config to the build context (print-config)',
        () async {
      // Real hook in a temp project: config from Dart, no oka.yaml.
      final tmp = await Directory.systemTemp.createTemp('oka_adr0010_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final repoRoot = Directory.current.path;
      await File('${tmp.path}/pubspec.yaml').writeAsString('''
name: dart_cfg
version: 1.0.0+1
environment:
  sdk: ^3.12.0
dependencies:
  oka:
    path: $repoRoot
  oka_android:
    path: $repoRoot/packages/oka_android
  oka_core:
    path: $repoRoot/packages/oka_core
''');
      await Directory('${tmp.path}/tool').create();
      await File('${tmp.path}/tool/oka_pipeline.dart').writeAsString('''
import 'package:oka_android/oka_android.dart';
import 'package:oka_core/oka_core.dart';

Future<void> main(List<String> args) => okaRun(
  args,
  oka: const Oka(
    pipelines: [
      AndroidPipeline(
        config: AndroidBuild(packageName: 'dev.test.dart_cfg', minSdk: '24'),
      ),
    ],
  ),
);
''');
      final get = await Process.run(
        'dart', ['pub', 'get'],
        workingDirectory: tmp.path,
        runInShell: true,
      );
      expect(get.exitCode, 0, reason: get.stderr as String);
      final result = await Process.run(
        'dart',
        ['run', 'tool/oka_pipeline.dart', '--print-config'],
        workingDirectory: tmp.path,
        runInShell: true,
      );
      expect(result.exitCode, 0, reason: result.stderr as String);
      final map =
          (jsonDecode(result.stdout as String) as Map).cast<String, dynamic>();
      expect((map['android'] as Map)['package_name'], 'dev.test.dart_cfg');
      expect((map['android'] as Map)['min_sdk'], '24');
    });
  });

  group('ADR-0010: entrypoint discovery (no oka.yaml needed)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('oka_discover_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('explicit oka.yaml dart_entrypoint wins', () async {
      await File('${tmp.path}/oka.yaml').writeAsString(
        'pipeline:\n  dart_entrypoint: bin/custom.dart\n',
      );
      await Directory('${tmp.path}/tool').create();
      await File('${tmp.path}/tool/oka_pipeline.dart').writeAsString('void m(){}');
      expect(await findPipelineEntrypoint(tmp.path), 'bin/custom.dart');
    });

    test('convention: tool/oka_pipeline.dart, then bin/', () async {
      expect(await findPipelineEntrypoint(tmp.path), isNull);
      await Directory('${tmp.path}/bin').create();
      await File('${tmp.path}/bin/oka_pipeline.dart').writeAsString('');
      expect(await findPipelineEntrypoint(tmp.path), 'bin/oka_pipeline.dart');
      await Directory('${tmp.path}/tool').create();
      await File('${tmp.path}/tool/oka_pipeline.dart').writeAsString('');
      expect(await findPipelineEntrypoint(tmp.path), 'tool/oka_pipeline.dart');
    });
  });
}
