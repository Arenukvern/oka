import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../build/android_builder.dart';
import '../build/flutter_apk_builder.dart';
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
      ..addFlag(
        'flutter',
        negatable: false,
        help:
            'Deprecated alias: default path is already no-Gradle Flutter packaging',
      )
      ..addFlag(
        'native-android',
        negatable: false,
        help:
            'Use legacy pure-Android SDK pipeline (no Flutter assemble; not for Flutter apps)',
      )
      ..addFlag(
        'soft-plugins',
        negatable: false,
        hide: true,
        help:
            'Escape hatch only: skip plugins that fail packaging. '
            'Default builds package all plugins completely.',
      )
      ..addFlag('aab',
          negatable: false, help: 'Build Android App Bundle (AAB) instead of APK')
      ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Verbose output')
      ..addOption('flavor', help: 'Build flavor')
      ..addOption('abi',
          help: 'Single ABI to build (e.g. arm64-v8a)', defaultsTo: '');

    final results = parser.parse(args);
    final verbose = results['verbose'] as bool;
    final useNativeAndroid = results['native-android'] as bool;
    final buildAab = results['aab'] as bool;
    // Default is complete plugin packaging (strict). --soft-plugins is a
    // hidden escape hatch, not the supported path for real apps.
    final softPlugins = results['soft-plugins'] as bool;
    final strictPlugins = !softPlugins;

    // Determine build mode
    final BuildMode mode;
    if (results['release'] as bool) {
      mode = BuildMode.release;
    } else if (results['profile'] as bool) {
      mode = BuildMode.profile;
    } else {
      mode = BuildMode.debug;
    }

    // Remaining args may include "apk" / "aab" subcommand tokens
    final rest = results.rest;
    final wantsAab =
        buildAab || rest.any((r) => r.toLowerCase() == 'aab');

    print('🔨 Building ${mode.name} ${wantsAab ? 'AAB' : 'APK'}...\n');

    if (wantsAab) {
      print(
        '⚠️  AAB via no-Gradle path is limited; building APK layout pipeline.\n'
        '   Full AAB/bundletool support is not the primary path yet.\n',
      );
    }

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

    final projectPath = Directory.current.path;
    final buildDir = p.join(projectPath, '.oka_cache', 'build', mode.name);
    final cacheDir = p.join(projectPath, '.oka_cache');
    await Directory(buildDir).create(recursive: true);

    final targetAbi = (results['abi'] as String?) ?? '';

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
      'target_abi': targetAbi,
      'build_aab': wantsAab,
    });

    final locator = SdkLocator(verbose: verbose);

    BuildArtifact artifact;
    if (useNativeAndroid) {
      // Legacy non-Flutter Android shell pipeline (not for Flutter apps).
      print('⚙️  Using legacy native-android pipeline (no Flutter assemble)\n');
      final builder = AndroidBuilder(locator, verbose: verbose);
      artifact = await builder.buildApk(buildContext);
    } else {
      // Default: no-Gradle Flutter APK (never flutter build apk / Gradle).
      if (softPlugins) {
        print('🧩 Soft plugin mode: unsupported plugins will be skipped\n');
      }
      final builder = FlutterApkBuilder(
        locator,
        verbose: verbose,
        strictPlugins: strictPlugins,
      );
      artifact = await builder.buildApk(buildContext);
    }

    if (!artifact.success) {
      print('\n❌ Build failed!');
      if (artifact.error.isNotEmpty) {
        print('   ${artifact.error}');
      }
      exit(1);
    }

    print('\n✅ Build successful!');
    print('📍 ${wantsAab ? 'AAB' : 'APK'}: ${artifact.apkPath}');
    print(
      '⏱️  Build time: ${(artifact.buildDuration / 1000).toStringAsFixed(1)}s',
    );
    print('📊 Size: ${(artifact.size / 1024 / 1024).toStringAsFixed(2)} MB');
  }
}
