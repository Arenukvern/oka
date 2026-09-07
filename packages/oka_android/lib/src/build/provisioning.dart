/// `oka get` Android provisioning implementations (ADR-0013/T1 + ADR-0015).
///
/// The CLI verb is a parse-and-delegate shim: these provisioners own the
/// sdk-manager mechanics, download/extract loops, and the user-facing
/// guidance strings (so `oka get` output stays byte-identical across the
/// move). Generic nouns (java, dep, android-sdk result formatting) stay in
/// the verb — they only call public oka_android APIs.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../auto_resolve.dart' show installKotlinCompiler;
import 'bundletool.dart' show downloadBundletool, findBundletool;
import 'toolchain.dart' show ResolvedToolchain;

/// Usage text for `oka get` (provisioning nouns + examples). Owned here so
/// the verb stays free of Android packaging specifics (ADR-0015).
const String okaGetUsageText = '''
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
''';

/// Android provisioning nouns for the generic `oka get` verb, resolved via
/// oka_android (ADR-0013/T1 tool-provider shape: the verb looks its noun up
/// here — no Android dispatch literals in the CLI, ADR-0015).
final Map<String, Future<void> Function()> androidProvisioners = {
  'r8': provisionR8,
  'build-tools': provisionBuildTools,
  'kotlin': provisionKotlinCompiler,
  'bundletool': provisionBundletool,
};

/// Install bundletool.jar for AAB verification (ADR-0004).
Future<void> provisionBundletool() async {
  print('📦 Installing bundletool (AAB verification tool)...\n');
  try {
    final existing = await findBundletool();
    if (existing != null) {
      print('✅ bundletool already available: $existing');
      return;
    }
    final jar = await downloadBundletool(verbose: true);
    print('✅ bundletool installed: $jar');
    print('');
    print('💡 Verify an AAB with:');
    print('   oka build aab --verify-aab');
  } catch (e) {
    print('❌ Failed to install bundletool: $e');
    exit(1);
  }
}

/// Install build-tools via the Android SDK Manager.
Future<void> provisionBuildTools() async {
  print('📦 Installing Android Build Tools...\n');

  final sdkmanager = await _findSdkManager();

  if (sdkmanager != null) {
    print('🔧 Using Android SDK Manager...\n');

    // Install latest build-tools
    final result = await Process.run(sdkmanager, [
      '--install',
      'build-tools;34.0.0',
    ], runInShell: true);

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

/// Install the R8 optimizer (build-tools;34.0.0 via the SDK Manager).
Future<void> provisionR8() async {
  print('📦 Installing R8 optimizer...\n');

  final toolchain = ResolvedToolchain();

  try {
    // Check if R8 already exists
    final existingR8 = await toolchain.findR8();
    if (existingR8 != null) {
      print('✅ R8 is already installed at: $existingR8');
      return;
    }

    // Find sdkmanager
    final sdkmanager = await _findSdkManager();

    if (sdkmanager != null) {
      print('🔧 Using Android SDK Manager to install build-tools...\n');

      // Install latest build-tools which includes R8
      final result = await Process.run(sdkmanager, [
        '--install',
        'build-tools;34.0.0',
      ], runInShell: true);

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

/// Install all missing build tools (build-tools, Kotlin, R8 as needed).
Future<void> provisionAllMissingTools() async {
  print('📦 Installing all missing dependencies...\n');

  final toolchain = ResolvedToolchain();
  final missing = <String>[];

  // Check what's missing
  print('🔍 Checking for missing tools...');

  try {
    await toolchain.findAapt2();
  } catch (e) {
    missing.add('aapt2');
  }

  try {
    await toolchain.findD8();
  } catch (e) {
    missing.add('d8');
  }

  final r8 = await toolchain.findR8();
  if (r8 == null) {
    missing.add('r8');
  }

  try {
    await toolchain.findZipalign();
  } catch (e) {
    missing.add('zipalign');
  }

  try {
    await toolchain.findApksigner();
  } catch (e) {
    missing.add('apksigner');
  }

  final kotlinc = await toolchain.findKotlinc();
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
    await provisionBuildTools();
  }

  if (missing.contains('kotlin')) {
    print('');
    await provisionKotlinCompiler();
  }

  if (missing.contains('r8')) {
    print('');
    await provisionR8();
  }
}

/// Install the Kotlin compiler into the oka tools dir (via the shared
/// artifact store, ADR-0013).
Future<void> provisionKotlinCompiler() async {
  print('📦 Installing Kotlin compiler...\n');

  try {
    // Check if Kotlin already exists
    final toolchain = ResolvedToolchain();
    final existingKotlin = await toolchain.findKotlinc();
    if (existingKotlin != null) {
      print('✅ Kotlin compiler is already installed at: $existingKotlin');
      return;
    }

    // Get oka cache directory
    final homeDir =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
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

    // Download + extract through the shared installer (ADR-0013: the
    // compiler zip is provisioned via the artifact store).
    print('📥 Downloading Kotlin $kotlinVersion...');
    print('   This may take a few minutes...\n');
    await installKotlinCompiler();

    print('✅ Kotlin compiler installed successfully!');
    print('   Location: $kotlinDir');
    print('   Version: $kotlinVersion');
    print('');
    print(
      '💡 Kotlin compiler will be used automatically by oka during builds',
    );
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

/// Find Android SDK Manager (sdkmanager): oka-managed SDK first, then PATH.
Future<String?> _findSdkManager() async {
  try {
    final toolchain = ResolvedToolchain();
    final androidSdk = await toolchain.findAndroidSdk();

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
    '  2. Go to Settings > Appearance & Behavior > System Settings > Android SDK',
  );
  print('  3. Click on "SDK Tools" tab');
  print('  4. Check "Android SDK Build-Tools" (install latest version)');
  print('  5. Click "Apply" to install');
  print('');
  print('Option 2: Using Command Line Tools');
  print('  1. Install Android Command Line Tools from:');
  print('     https://developer.android.com/studio#command-tools');
  print(r'  2. Extract to: $ANDROID_SDK/cmdline-tools/latest/');
  print('  3. Run: sdkmanager "build-tools;34.0.0"');
  print('');
  print('Option 3: Using sdkmanager directly');
  print('  If you have sdkmanager installed, run:');
  print(r'  $ sdkmanager "build-tools;34.0.0"');
  print('');
  print('After installation, run "oka doctor" to verify.');
  print('═══════════════════════════════════════════════════════════');
}
