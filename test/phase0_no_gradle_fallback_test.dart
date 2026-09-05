import 'dart:io';

import 'package:oka_android/src/build/flutter_apk_builder.dart';
import 'package:oka_android/src/build/flutter_assemble.dart';
import 'package:oka_android/src/build/sdk_locator.dart';
import 'package:oka_core/src/config/build_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('phase0: no Gradle / no flutter build apk fallback', () {
    test('assemble args never request flutter build apk', () {
      for (final mode in BuildMode.values) {
        final args = buildFlutterAssembleArgs(
          outputDir: 'out',
          targetFile: 'lib/main.dart',
          mode: mode,
          targetPlatform: 'android-arm64',
        );
        expect(args, isNot(contains('apk')));
        expect(args.join(' '), isNot(contains('gradle')));
        expect(args.first, 'assemble');
      }
    });

    test('FlutterApkBuilder never shells out to Gradle (source contract)',
        () async {
      final root = Directory.current.path;

      final builderSrc = File(
        p.join(root, 'packages', 'oka_android', 'lib', 'src', 'build', 'flutter_apk_builder.dart'),
      );
      final text = await builderSrc.readAsString();
      expect(text, isNot(contains("'build', 'apk'")));
      expect(text, isNot(contains('"build", "apk"')));
      expect(text, isNot(contains('gradlew')));
      expect(text, contains('assemble'));
      // Orchestrator must call FlutterAssembler / assemble (the only build path)
      expect(text, contains('FlutterAssembler'));
    });
    test('BuildCommand default path uses FlutterApkBuilder', () async {
      final src = await File(
        p.join(
          Directory.current.path,
          'lib',
          'src',
          'cli',
          'build_command.dart',
        ),
      ).readAsString();
      expect(src, contains('FlutterApkBuilder'));
      expect(src, isNot(contains("results['flutter']")));
      // native-android is opt-in only
      expect(src, contains('native-android'));
    });

    test('SDK missing yields failed artifact without claiming success', () async {
      final tmp = await Directory.systemTemp.createTemp('oka_sdk_miss_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });

      // Minimal flutter project-ish tree
      await File(p.join(tmp.path, 'lib', 'main.dart')).create(recursive: true);
      await File(p.join(tmp.path, 'lib', 'main.dart'))
          .writeAsString('void main() {}');
      await File(p.join(tmp.path, 'pubspec.yaml')).writeAsString('''
name: fixture
version: 1.0.0
environment:
  sdk: ^3.10.0
dependencies:
  flutter:
    sdk: flutter
flutter:
  uses-material-design: true
''');

      final buildDir = p.join(tmp.path, '.oka_cache', 'build', 'debug');
      final ctx = BuildContext.fromJson({
        'project_path': tmp.path,
        'build_dir': buildDir,
        'mode': 'debug',
        'config': {
          'name': 'fixture',
          'version': '1.0.0',
          'android': {
            'package_name': 'com.example.fixture',
            'min_sdk': '21',
            'target_sdk': '34',
            'compile_sdk': '34',
            'version_code': 1,
            'version_name': '1.0.0',
            'abis': ['arm64-v8a'],
            'java_version': 11,
          },
          'flutter': {
            'entrypoint': 'lib/main.dart',
            'build_mode': 'debug',
            'target_platform': 'android-arm64',
          },
        },
        'cache_dir': p.join(tmp.path, '.oka_cache'),
        'temp_dir': p.join(buildDir, 'temp'),
        'verbose': false,
        'target_abi': 'arm64-v8a',
        'build_aab': false,
      });

      // Point SdkLocator at non-existent SDK
      final locator = SdkLocator(
        androidSdkPath: p.join(tmp.path, 'no_android_sdk'),
        verbose: false,
      );
      final builder = FlutterApkBuilder(locator, verbose: false);
      final artifact = await builder.buildApk(ctx);

      expect(artifact.success, isFalse);
      expect(artifact.apkPath, isEmpty);
      expect(
        artifact.error.toLowerCase(),
        anyOf(contains('android sdk'), contains('build-tools'), contains('not')),
      );
      // Failure must mention doctor / SDK guidance (no silent Gradle success)
      expect(
        artifact.error.toLowerCase(),
        anyOf(contains('doctor'), contains('android_sdk'), contains('sdk')),
      );
    });
  });
}
