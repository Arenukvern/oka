import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'package:oka_android/src/build/sdk_locator.dart';
import 'package:oka_android/src/build/version_manager.dart';
import 'package:oka_core/src/config/oka_config.dart';
import '../version.dart';

/// Recursively converts YamlMap/YamlList to Map/List
dynamic _yamlToJson(dynamic value) {
  if (value is YamlMap) {
    return value.map((k, v) => MapEntry(k.toString(), _yamlToJson(v)));
  } else if (value is YamlList) {
    return value.map(_yamlToJson).toList();
  }
  return value;
}

/// Doctor command to check system requirements
class DoctorCommand {
  Future<void> run(List<String> args) async {
    print('🔍 Oka Doctor - Checking system configuration...\n');

    final okaVersion = getOkaVersion();
    print('[Oka Version]');
    print('  ℹ️  Oka v$okaVersion');
    print('');

    final locator = SdkLocator();
    var allGood = true;

    // Load oka.yaml if it exists for version requirements
    OkaConfig? config;
    final okaYamlFile = File('oka.yaml');
    if (await okaYamlFile.exists()) {
      try {
        final okaYamlContent = await okaYamlFile.readAsString();
        final okaYamlData = loadYaml(okaYamlContent);
        config = OkaConfig.fromJson(_yamlToJson(okaYamlData));
      } catch (e) {
        // Failed to parse config
      }
    }

    // Check Flutter SDK
    print('[Flutter SDK]');
    try {
      final flutterSdk = await locator.findFlutterSdk();
      print('  ✅ Found at: $flutterSdk');

      // Check Flutter version
      final result = await Process.run('flutter', ['--version']);
      if (result.exitCode == 0) {
        final version = (result.stdout as String).split('\n')[0];
        print('  ℹ️  $version');
      }
    } catch (e) {
      print('  ❌ Not found: $e');
      allGood = false;
    }
    print('');

    // Check Android SDK
    print('[Android SDK]');
    try {
      final androidSdk = await locator.findAndroidSdk();
      print('  ✅ Found at: $androidSdk');

      // Check for required tools
      final tools = {
        'aapt2': locator.findAapt2(),
        'd8': locator.findD8(),
        'zipalign': locator.findZipalign(),
        'apksigner': locator.findApksigner(),
        'adb': locator.findAdb(),
      };

      for (final entry in tools.entries) {
        try {
          final path = await entry.value;
          print('  ✅ ${entry.key}: ${p.basename(p.dirname(path))}');
        } catch (e) {
          print('  ❌ ${entry.key}: Not found');
          allGood = false;
        }
      }

      // Check R8 separately (it's optional but recommended)
      try {
        final r8Path = await locator.findR8();
        if (r8Path != null) {
          print('  ✅ r8: ${p.basename(p.dirname(r8Path))}');
        } else {
          print(
              '  ⚠️  r8: Not found (optional, but recommended for release builds)');
          print('      💡 Run "oka get r8" to install');
        }
      } catch (e) {
        print(
            '  ⚠️  r8: Not found (optional, but recommended for release builds)');
        print('      💡 Run "oka get r8" to install');
      }
    } catch (e) {
      print('  ❌ Not found: $e');
      allGood = false;
    }
    print('');

    // Check Java
    print('[Java Development Kit]');
    try {
      await locator.findJavac();
      print('  ✅ javac found');

      final result = await Process.run('java', ['-version']);
      if (result.exitCode == 0) {
        final versionOutput = (result.stderr as String).split('\n')[0];
        print('  ℹ️  $versionOutput');

        // Extract major version
        final versionMatch = RegExp(r'version "(\d+)\.?(\d*)\.?(\d*)[_\-]?.*?"')
            .firstMatch(versionOutput);

        if (versionMatch != null) {
          final major = versionMatch.group(1)!;
          final currentMajor = major == '1' ? versionMatch.group(2)! : major;

          // Check if there's a required version in oka.yaml
          if (config != null) {
            final requiredVersion = config.android.requiredJavaVersion;
            final kotlinVersion = config.android.kotlinVersion;

            if (requiredVersion != null) {
              print('  ℹ️  Required by oka.yaml: Java $requiredVersion');

              try {
                final currentInt = int.parse(currentMajor);
                final requiredInt = int.parse(requiredVersion);

                if (currentInt > requiredInt) {
                  print(
                      '  ⚠️  Warning: Current Java ($currentMajor) is newer than required ($requiredVersion)');
                  if (kotlinVersion != null) {
                    print('     Kotlin $kotlinVersion may not be compatible');
                  }
                } else if (currentInt == requiredInt) {
                  print('  ✓ Java version matches requirements');
                }
              } catch (e) {
                // Could not parse versions
              }
            }

            if (kotlinVersion != null) {
              print('  ℹ️  Kotlin version: $kotlinVersion');
            }
          }
        }
      }
    } catch (e) {
      print('  ❌ Not found: $e');
      print('  💡 Install JDK 11 or later');
      allGood = false;
    }

    // Check version managers
    print('');
    print('[Java Version Managers]');
    final versionManager = await VersionManager.detectBestVersionManager();
    if (versionManager != null) {
      print('  ✅ ${versionManager.name} detected');

      final installedVersions =
          await versionManager.listInstalledJavaVersions();
      if (installedVersions.isNotEmpty) {
        print('  ℹ️  Installed Java versions:');
        for (final version in installedVersions.take(5)) {
          print('     - $version');
        }
        if (installedVersions.length > 5) {
          print('     ... and ${installedVersions.length - 5} more');
        }
      }
    } else {
      print('  ⚠️  No version manager detected');
      print(
          '     Consider installing SDKMAN! (Linux/macOS) or using winget (Windows)');
      print('     This allows automatic Java version switching');
    }
    print('');

    // Check Kotlin (optional)
    print('[Kotlin Compiler (optional)]');
    try {
      final kotlinc = await locator.findKotlinc();
      if (kotlinc != null) {
        print('  ✅ kotlinc found');

        final result = await Process.run('kotlinc', ['-version']);
        if (result.exitCode == 0) {
          print('  ℹ️  ${result.stdout}');
        }
      } else {
        print('  ⚠️  Not found (will be downloaded if needed)');
      }
    } catch (e) {
      print('  ⚠️  Not found (will be downloaded if needed)');
    }
    print('');

    // Check AI configuration
    print('[AI Agent]');
    final geminiKey = Platform.environment['GEMINI_API_KEY'];
    if (geminiKey != null && geminiKey.isNotEmpty) {
      print('  ✅ GEMINI_API_KEY is set');
    } else {
      print('  ⚠️  GEMINI_API_KEY not set');
      print('  💡 Set GEMINI_API_KEY for Gradle conversion');
      print('  💡 Get API key from: https://makersuite.google.com/app/apikey');
    }

    if (Platform.isMacOS) {
      print(
          '  ℹ️  Running on macOS - Foundation Models will be used when available');
    }
    print('');

    // Check oka.yaml
    print('[Project Configuration]');
    final okaYaml = File('oka.yaml');
    if (await okaYaml.exists()) {
      print('  ✅ oka.yaml found');
    } else {
      print('  ⚠️  oka.yaml not found');
      print('  💡 Run "oka init" to create it');
    }
    print('');

    // ADR-0007: incremental + self-resolution state
    print('[Build Health (ADR-0007)]');

    // Kotlin compiler (auto-install available)
    try {
      final kotlinc = await locator.findKotlinc();
      print(kotlinc != null
          ? '  ✅ kotlinc: $kotlinc'
          : '  ⚠️  kotlinc not found — builds auto-install on demand\n'
              '     💡 Pre-install: "oka get kotlin"');
    } catch (_) {
      print('  ⚠️  kotlinc not found — builds auto-install on demand');
    }

    // bundletool (AAB verification)
    final bt = Directory(
      p.join(
        Platform.environment['HOME'] ??
            Platform.environment['USERPROFILE'] ??
            '.',
        '.oka',
        'tools',
      ),
    );
    final hasBundletool = bt.existsSync() &&
        bt.listSync().any((e) => p.basename(e.path).startsWith('bundletool'));
    print(
      hasBundletool
          ? '  ✅ bundletool: available for AAB verification'
          : '  ℹ️  bundletool not installed (only needed for --verify-aab) —'
              ' "oka get bundletool"',
    );

    // Maven cache state
    final mavenCache = Directory(
      p.join(
        Platform.environment['HOME'] ??
            Platform.environment['USERPROFILE'] ??
            '.',
        '.oka',
        'cache',
        'maven',
      ),
    );
    if (mavenCache.existsSync()) {
      final artifacts = mavenCache
          .listSync(recursive: true)
          .whereType<File>()
          .length;
      print('  ✅ maven cache: $artifacts artifacts');
    } else {
      print('  ℹ️  maven cache empty — first build will download dependencies');
    }

    // Incremental step cache + package_config staleness
    final stepCache = File('.oka_cache/build/debug/step_cache.json');
    print(
      stepCache.existsSync()
          ? '  ✅ incremental cache: present (debug)'
          : '  ℹ️  incremental cache: empty — first build is a cold build',
    );
    final packageConfig = File('.dart_tool/package_config.json');
    final pubspec = File('pubspec.yaml');
    if (pubspec.existsSync() &&
        (!packageConfig.existsSync() ||
            pubspec.lastModifiedSync().isAfter(
              packageConfig.lastModifiedSync(),
            ))) {
      print('  ⚠️  package_config.json is stale — build will run pub get');
    } else {
      print('  ✅ package_config.json fresh');
    }
    print('');

    // Summary
    if (allGood) {
      print('✅ All checks passed! You\'re ready to use Oka.');
    } else {
      print('⚠️  Some checks failed. Please fix the issues above.');
      print('   Run "oka doctor" again after fixing.');
    }
  }
}
