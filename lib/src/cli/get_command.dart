import 'dart:io';

import 'package:path/path.dart' as p;

import '../build/android_sdk_installer.dart';
import '../build/sdk_locator.dart';
import '../build/version_manager.dart';

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
      case 'android-sdk':
      case 'packaging-sdk':
      case 'sdk':
        await _installAndroidSdk();
        break;
      case 'r8':
        await _installR8();
        break;
      case 'build-tools':
        await _installBuildTools();
        break;
      case 'kotlin':
        await _installKotlin();
        break;
      case 'java':
        if (args.length < 2) {
          print('❌ Please specify Java version');
          print('   Example: oka get java 21');
          exit(1);
        }
        await _installJava(args[1]);
        break;
      case 'all':
        await _installAndroidSdk();
        await _installAll();
        break;
      default:
        print('❌ Unknown dependency: $target');
        _printUsage();
        exit(1);
    }
  }

  Future<void> _installAndroidSdk() async {
    print('📦 Installing oka-managed packaging Android SDK...\n');
    final installer = AndroidSdkInstaller(verbose: true);
    print('   Root: ${installer.sdkRoot}');
    final result = await installer.installPackagingSdk();
    if (result.success) {
      print('✅ ${result.message}');
      print('   Packages: ${result.packages.join(', ')}');
      print('');
      print('💡 Export for this shell (optional):');
      print('   export OKA_ANDROID_SDK=${result.sdkRoot}');
      print('   export ANDROID_SDK_ROOT=${result.sdkRoot}');
      print('   Run: oka doctor');
    } else {
      print('❌ ${result.message}');
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

    final kotlinc = await locator.findKotlinc();
    if (kotlinc == null) {
      missing.add('kotlin');
    }

    if (missing.isEmpty) {
      print('✅ All build tools are already installed!');
      return;
    }

    print('');
    print('Missing tools: ${missing.join(", ")}');
    print('');

    // Install missing tools
    if (missing.any((t) => t != 'kotlin' && t != 'r8')) {
      await _installBuildTools();
    }

    if (missing.contains('kotlin')) {
      print('');
      await _installKotlin();
    }

    if (missing.contains('r8')) {
      print('');
      await _installR8();
    }
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

  /// Install Kotlin compiler
  Future<void> _installKotlin() async {
    print('📦 Installing Kotlin compiler...\n');

    try {
      // Check if Kotlin already exists
      final locator = SdkLocator();
      final existingKotlin = await locator.findKotlinc();
      if (existingKotlin != null) {
        print('✅ Kotlin compiler is already installed at: $existingKotlin');
        return;
      }

      // Get oka cache directory
      final homeDir = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          '';
      if (homeDir.isEmpty) {
        throw Exception('Could not determine home directory');
      }

      final okaCacheDir = p.join(homeDir, '.oka', 'tools');
      await Directory(okaCacheDir).create(recursive: true);

      // Kotlin version to download
      // Using 2.1.0 for latest Java compatibility
      const kotlinVersion = '2.1.0';
      final kotlinDir = p.join(okaCacheDir, 'kotlin-$kotlinVersion');

      // Check if already downloaded but not in PATH
      if (await Directory(kotlinDir).exists()) {
        print('✅ Kotlin $kotlinVersion is already downloaded at: $kotlinDir');
        print('💡 Kotlin compiler will be used automatically by oka');
        return;
      }

      // Download Kotlin
      print('📥 Downloading Kotlin $kotlinVersion...');
      print('   This may take a few minutes...\n');

      const downloadUrl =
          'https://github.com/JetBrains/kotlin/releases/download/v$kotlinVersion/kotlin-compiler-$kotlinVersion.zip';

      // Download using curl
      final tempFile = p.join(okaCacheDir, 'kotlin-compiler.zip');
      final downloadResult = await Process.run(
        'curl',
        ['-L', '-o', tempFile, downloadUrl],
        runInShell: true,
      );

      if (downloadResult.exitCode != 0) {
        throw Exception('Failed to download Kotlin: ${downloadResult.stderr}');
      }

      print('📦 Extracting Kotlin compiler...');

      // Extract using unzip
      final extractResult = await Process.run(
        'unzip',
        ['-q', tempFile, '-d', okaCacheDir],
        runInShell: true,
      );

      if (extractResult.exitCode != 0) {
        throw Exception('Failed to extract Kotlin: ${extractResult.stderr}');
      }

      // Rename extracted directory to include version
      final extractedDir = p.join(okaCacheDir, 'kotlinc');
      if (await Directory(extractedDir).exists()) {
        await Directory(extractedDir).rename(kotlinDir);
      }

      // Clean up temp file
      await File(tempFile).delete();

      // Make kotlinc executable
      if (!Platform.isWindows) {
        final kotlincPath = p.join(kotlinDir, 'bin', 'kotlinc');
        await Process.run('chmod', ['+x', kotlincPath]);
      }

      print('✅ Kotlin compiler installed successfully!');
      print('   Location: $kotlinDir');
      print('   Version: $kotlinVersion');
      print('');
      print(
          '💡 Kotlin compiler will be used automatically by oka during builds');
      print('');
      print('To use it system-wide, add to your PATH:');
      if (Platform.isWindows) {
        print('   \$env:PATH += ";$kotlinDir\\bin"');
      } else {
        print('   export PATH="\$PATH:$kotlinDir/bin"');
      }
    } catch (e) {
      print('❌ Error: $e');
      print('');
      print('You can manually install Kotlin from:');
      print('  https://kotlinlang.org/docs/command-line.html');
    }
  }

  /// Install specific Java version
  Future<void> _installJava(String version) async {
    print('📦 Installing Java $version...\n');

    // Detect available version manager
    final versionManager = await VersionManager.detectBestVersionManager();

    if (versionManager == null) {
      print('❌ No version manager detected');
      print('');
      _printJavaInstallInstructions(version);
      exit(1);
    }

    print('🔍 Using ${versionManager.name} for installation...');
    print('');

    try {
      // Check if already installed
      final installedVersions =
          await versionManager.listInstalledJavaVersions();
      final alreadyInstalled = installedVersions.any(
        (v) =>
            v == version ||
            v.startsWith('$version.') ||
            v.startsWith('$version-'),
      );

      if (alreadyInstalled) {
        print('✅ Java $version is already installed');
        print('');
        print('💡 Run "oka doctor" to verify installation');
        return;
      }

      // Install
      final success = await versionManager.installJavaVersion(version);

      if (success) {
        print('');
        print('✅ Java $version installed successfully!');
        print('');
        print('💡 Run "oka doctor" to verify installation');
      } else {
        print('');
        print('❌ Failed to install Java $version');
        _printJavaInstallInstructions(version);
        exit(1);
      }
    } catch (e) {
      print('❌ Error: $e');
      _printJavaInstallInstructions(version);
      exit(1);
    }
  }

  /// Print Java installation instructions
  void _printJavaInstallInstructions(String version) {
    print('');
    print('═══════════════════════════════════════════════════════════');
    print('📋 Manual Java Installation Instructions');
    print('═══════════════════════════════════════════════════════════');
    print('');

    if (Platform.isLinux || Platform.isMacOS) {
      print('Option 1: Install SDKMAN! (recommended)');
      print('  curl -s "https://get.sdkman.io" | bash');
      print('  sdk install java $version-tem');
      print('');
      print('Option 2: Install asdf');
      print('  https://asdf-vm.com/guide/getting-started.html');
      print('  asdf plugin-add java');
      print('  asdf install java temurin-$version');
      print('');
    }

    if (Platform.isWindows) {
      print('Option 1: Use winget');
      print('  winget install EclipseAdoptium.Temurin.$version.JDK');
      print('');
    }

    if (Platform.isMacOS) {
      print('Option 3: Use Homebrew');
      print('  brew install openjdk@$version');
      print('');
    }

    print('Or download directly from:');
    print('  https://adoptium.net/');
    print('═══════════════════════════════════════════════════════════');
    print('');
  }

  /// Print usage information
  void _printUsage() {
    print('''
Usage: oka get <dependency>

Install missing build dependencies.

Dependencies:
  android-sdk     Install oka-managed packaging SDK (aapt2/d8/zipalign/apksigner)
  packaging-sdk   Alias for android-sdk
  r8              Install R8 optimizer for release builds
  build-tools     Install Android Build Tools (via sdkmanager if present)
  kotlin          Install Kotlin compiler
  java <version>  Install specific Java JDK version
  all             Install android-sdk + other missing tools

Examples:
  oka get android-sdk   # Bootstrap packaging SDK under ~/.oka/android-sdk
  oka get kotlin        # Install Kotlin compiler
  oka get java 21       # Install Java 21
  oka get r8            # Install R8 optimizer
  oka get all           # Install everything missing

Run "oka doctor" to see what's currently installed.
''');
  }
}
