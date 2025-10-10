import 'dart:io';

import 'package:path/path.dart' as p;

import '../build/sdk_locator.dart';
import '../version.dart';

/// Doctor command to check system requirements
class DoctorCommand {
  Future<void> run(List<String> args) async {
    print('🔍 Oka Doctor - Checking system configuration...\n');

    final okaVersion = await getOkaVersion();
    print('[Oka Version]');
    print('  ℹ️  Oka v$okaVersion');
    print('');

    final locator = SdkLocator();
    var allGood = true;

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
        'r8': locator.findR8(),
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
        final version = (result.stderr as String).split('\n')[0];
        print('  ℹ️  $version');
      }
    } catch (e) {
      print('  ❌ Not found: $e');
      print('  💡 Install JDK 11 or later');
      allGood = false;
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

    // Summary
    if (allGood) {
      print('✅ All checks passed! You\'re ready to use Oka.');
    } else {
      print('⚠️  Some checks failed. Please fix the issues above.');
      print('   Run "oka doctor" again after fixing.');
    }
  }
}
