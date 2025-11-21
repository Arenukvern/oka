import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../build/android_builder.dart';
import '../build/flutter_android_builder.dart';
import '../build/sdk_locator.dart';
import '../config/build_context.dart';
import '../config/oka_config.dart';

/// Recursively converts YamlMap/YamlList to Map/List
dynamic _yamlToJson(dynamic value) {
  if (value is YamlMap) {
    return value.map((k, v) => MapEntry(k.toString(), _yamlToJson(v)));
  } else if (value is YamlList) {
    return value.map(_yamlToJson).toList();
  }
  return value;
}

/// Build command to compile APK or AAB
class BuildCommand {
  Future<void> run(List<String> args) async {
    final parser = ArgParser()
      ..addFlag('release', negatable: false, help: 'Build release variant')
      ..addFlag('debug',
          negatable: false, help: 'Build debug variant (default)')
      ..addFlag('profile', negatable: false, help: 'Build profile variant')
      ..addFlag('flutter', negatable: false, help: 'Use Flutter hybrid build pipeline (cargo-apk)')
      ..addFlag('aab', negatable: false, help: 'Build Android App Bundle (AAB) instead of APK')
      ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Verbose output')
      ..addOption('flavor', help: 'Build flavor');

    final results = parser.parse(args);
    final verbose = results['verbose'] as bool;
    final useFlutter = results['flutter'] as bool;
    final buildAab = results['aab'] as bool;

    // Determine build mode
    final BuildMode mode;
    if (results['release'] as bool) {
      mode = BuildMode.release;
    } else if (results['profile'] as bool) {
      mode = BuildMode.profile;
    } else {
      mode = BuildMode.debug;
    }

    print('🔨 Building ${mode.name} ${buildAab ? 'AAB' : 'APK'}...\n');

    // Load oka.yaml
    final okaYamlFile = File('oka.yaml');
    if (!await okaYamlFile.exists()) {
      print('❌ oka.yaml not found');
      print('   Run "oka init" first to create configuration');
      exit(1);
    }

    final okaYamlContent = await okaYamlFile.readAsString();
    final okaYamlData = loadYaml(okaYamlContent);
    final config = OkaConfig.fromJson(_yamlToJson(okaYamlData));

    if (verbose) {
      print('📋 Configuration:');
      print('   Package: ${config.android.packageName}');
      print('   Min SDK: ${config.android.minSdk}');
      print('   Target SDK: ${config.android.targetSdk}');
      print('   Compile SDK: ${config.android.compileSdk}');
      print('');
    }

    // Setup build context
    final projectPath = Directory.current.path;
    final buildDir = p.join(projectPath, '.oka_cache', 'build', mode.name);
    final cacheDir = p.join(projectPath, '.oka_cache');

    // Create AndroidManifest.xml if needed
    await _prepareManifest(config, buildDir);

    final buildContext = BuildContext.fromJson({
      'project_path': projectPath,
      'build_dir': buildDir,
      'mode': mode.name,
      'config': config.toJson(),
      'cache_dir': cacheDir,
      'temp_dir': p.join(buildDir, 'temp'),
      'flutter_sdk_path': '',
      'android_sdk_path': '',
      'verbose': verbose,
      'flavor': results['flavor'] ?? '',
      'target_abi': 'arm64-v8a',
      'build_aab': buildAab,
    });

    // Build APK
    final locator = SdkLocator(verbose: verbose);

    BuildArtifact artifact;
    if (useFlutter) {
      // Use Flutter hybrid build pipeline
      final builder = FlutterAndroidBuilder(locator, verbose: verbose);
      artifact = await builder.buildFlutterApk(buildContext);
    } else {
      // Use traditional Android SDK build pipeline
      final builder = AndroidBuilder(locator, verbose: verbose);
      artifact = await builder.buildApk(buildContext);
    }

    if (!artifact.success) {
      print('\n❌ Build failed!');
      exit(1);
    }

    print('\n✅ Build successful!');
    print('📍 ${buildAab ? 'AAB' : 'APK'}: ${artifact.apkPath}');
    print(
        '⏱️  Build time: ${(artifact.buildDuration / 1000).toStringAsFixed(1)}s');
    print('📊 Size: ${(artifact.size / 1024 / 1024).toStringAsFixed(2)} MB');
  }

  Future<void> _prepareManifest(OkaConfig config, String buildDir) async {
    // Create build directory
    await Directory(buildDir).create(recursive: true);

    // Create basic AndroidManifest.xml
    final manifestPath = p.join(buildDir, 'AndroidManifest.xml');
    final manifest = '''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="${config.android.packageName}">
    
    <uses-sdk
        android:minSdkVersion="${config.android.minSdk}"
        android:targetSdkVersion="${config.android.targetSdk}" />
    
    <application
        android:label="${config.name}"
        android:icon="@mipmap/ic_launcher">
        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
''';

    await File(manifestPath).writeAsString(manifest);
  }
}
