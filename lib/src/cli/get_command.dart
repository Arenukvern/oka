import 'dart:io';

import 'package:path/path.dart' as p;

import '../build/sdk_locator.dart';

/// Get command to install missing Android SDK dependencies
class GetCommand {
  /// Run the get command
  Future<void> run(List<String> args) async {
    if (args.isEmpty) {
      _printUsage();
      return;
    }

    final target = args[0].toLowerCase();

    switch (target) {
      case 'r8':
        await _installR8();
        break;
      case 'build-tools':
        await _installBuildTools();
        break;
      case 'all':
        await _installAll();
        break;
      default:
        print('❌ Unknown dependency: $target');
        _printUsage();
        exit(1);
    }
  }

  /// Install R8 optimizer
  Future<void> _installR8() async {
    print('📦 Installing R8 optimizer...\n');

    final locator = SdkLocator();

    try {
      // Check if R8 already exists
      final existingR8 = await locator.findR8();
      if (existingR8 != null) {
        print('✅ R8 is already installed at: $existingR8');
        return;
      }

      // Find sdkmanager
      final sdkmanager = await _findSdkManager();

      if (sdkmanager != null) {
        print('🔧 Using Android SDK Manager to install build-tools...\n');

        // Install latest build-tools which includes R8
        final result = await Process.run(
          sdkmanager,
          ['--install', 'build-tools;34.0.0'],
          runInShell: true,
        );

        if (result.exitCode == 0) {
          print('✅ Build tools installed successfully!');
          print('   R8 should now be available.');
          print('');
          print('💡 Run "oka doctor" to verify installation');
        } else {
          print('❌ Failed to install build-tools');
          print('   Error: ${result.stderr}');
          _printManualInstructions();
        }
      } else {
        print('⚠️  Android SDK Manager (sdkmanager) not found');
        _printManualInstructions();
      }
    } catch (e) {
      print('❌ Error: $e');
      _printManualInstructions();
    }
  }

  /// Install build-tools
  Future<void> _installBuildTools() async {
    print('📦 Installing Android Build Tools...\n');

    final sdkmanager = await _findSdkManager();

    if (sdkmanager != null) {
      print('🔧 Using Android SDK Manager...\n');

      // Install latest build-tools
      final result = await Process.run(
        sdkmanager,
        ['--install', 'build-tools;34.0.0'],
        runInShell: true,
      );

      if (result.exitCode == 0) {
        print('✅ Build tools installed successfully!');
        print('');
        print('💡 Run "oka doctor" to verify installation');
      } else {
        print('❌ Failed to install build-tools');
        print('   Error: ${result.stderr}');
        _printManualInstructions();
      }
    } else {
      print('⚠️  Android SDK Manager (sdkmanager) not found');
      _printManualInstructions();
    }
  }

  /// Install all missing dependencies
  Future<void> _installAll() async {
    print('📦 Installing all missing dependencies...\n');

    final locator = SdkLocator();
    final missing = <String>[];

    // Check what's missing
    print('🔍 Checking for missing tools...');

    try {
      await locator.findAapt2();
    } catch (e) {
      missing.add('aapt2');
    }

    try {
      await locator.findD8();
    } catch (e) {
      missing.add('d8');
    }

    final r8 = await locator.findR8();
    if (r8 == null) {
      missing.add('r8');
    }

    try {
      await locator.findZipalign();
    } catch (e) {
      missing.add('zipalign');
    }

    try {
      await locator.findApksigner();
    } catch (e) {
      missing.add('apksigner');
    }

    if (missing.isEmpty) {
      print('✅ All Android SDK tools are already installed!');
      return;
    }

    print('');
    print('Missing tools: ${missing.join(", ")}');
    print('');

    // Install build-tools to get all missing tools
    await _installBuildTools();
  }

  /// Find Android SDK Manager (sdkmanager)
  Future<String?> _findSdkManager() async {
    try {
      final locator = SdkLocator();
      final androidSdk = await locator.findAndroidSdk();

      // Check cmdline-tools locations
      final possiblePaths = [
        p.join(androidSdk, 'cmdline-tools', 'latest', 'bin', 'sdkmanager'),
        p.join(androidSdk, 'tools', 'bin', 'sdkmanager'),
      ];

      for (final path in possiblePaths) {
        if (await File(path).exists()) {
          return path;
        }
      }

      // Try to find in PATH
      final result = await Process.run('which', ['sdkmanager']);
      if (result.exitCode == 0) {
        return (result.stdout as String).trim();
      }
    } catch (e) {
      // SDK not found
    }

    return null;
  }

  /// Print manual installation instructions
  void _printManualInstructions() {
    print('');
    print('═══════════════════════════════════════════════════════════');
    print('📋 Manual Installation Instructions');
    print('═══════════════════════════════════════════════════════════');
    print('');
    print('Option 1: Using Android Studio');
    print('  1. Open Android Studio');
    print(
        '  2. Go to Settings > Appearance & Behavior > System Settings > Android SDK');
    print('  3. Click on "SDK Tools" tab');
    print('  4. Check "Android SDK Build-Tools" (install latest version)');
    print('  5. Click "Apply" to install');
    print('');
    print('Option 2: Using Command Line Tools');
    print('  1. Install Android Command Line Tools from:');
    print('     https://developer.android.com/studio#command-tools');
    print('  2. Extract to: \$ANDROID_SDK/cmdline-tools/latest/');
    print('  3. Run: sdkmanager "build-tools;34.0.0"');
    print('');
    print('Option 3: Using sdkmanager directly');
    print('  If you have sdkmanager installed, run:');
    print('  \$ sdkmanager "build-tools;34.0.0"');
    print('');
    print('After installation, run "oka doctor" to verify.');
    print('═══════════════════════════════════════════════════════════');
  }

  /// Print usage information
  void _printUsage() {
    print('''
Usage: oka get <dependency>

Install missing Android SDK dependencies.

Dependencies:
  r8            Install R8 optimizer for release builds
  build-tools   Install Android Build Tools
  all           Install all missing dependencies

Examples:
  oka get r8            # Install R8 optimizer
  oka get build-tools   # Install Android Build Tools
  oka get all           # Install everything missing

Run "oka doctor" to see what's currently installed.
''');
  }
}
