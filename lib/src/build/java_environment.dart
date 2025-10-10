import 'dart:io';

import 'package:path/path.dart' as p;

import 'version_manager.dart';

/// {@template java_environment}
/// Resolves and manages Java runtime environments for Kotlin compilation
///
/// Handles Java version detection, switching, and installation using
/// system version managers (SDKMAN!, asdf, winget)
/// {@endtemplate}
class JavaEnvironment {
  final bool _verbose;

  /// {@macro java_environment}
  JavaEnvironment({bool verbose = false}) : _verbose = verbose;

  /// Resolve Java environment for a specific version requirement
  ///
  /// Returns a map of environment variables (JAVA_HOME, PATH) to use
  /// for running kotlinc and javac processes
  ///
  /// [requiredVersion] is the major Java version (e.g., "21", "17")
  /// [autoInstall] whether to automatically install missing versions
  Future<Map<String, String>?> resolveJavaEnvironment(
    String? requiredVersion, {
    bool autoInstall = true,
  }) async {
    // If no specific version required, use system default
    if (requiredVersion == null || requiredVersion.isEmpty) {
      if (_verbose) {
        print('No specific Java version required, using system default');
      }
      return null;
    }

    if (_verbose) {
      print('🔍 Resolving Java environment for version $requiredVersion');
    }

    // Check current Java version
    final currentVersion = await _getCurrentJavaVersion();
    if (currentVersion != null) {
      if (_verbose) {
        print('   Current Java version: $currentVersion');
      }

      // Check if current version is compatible
      if (_isVersionCompatible(currentVersion, requiredVersion)) {
        if (_verbose) {
          print('   ✓ Current Java version is compatible');
        }
        return null; // Use system default
      } else {
        if (_verbose) {
          print(
              '   ⚠️  Current Java version ($currentVersion) may not be compatible with required version ($requiredVersion)');
        }
      }
    }

    // Try to find/install compatible Java version
    final versionManager = await VersionManager.detectBestVersionManager();

    if (versionManager == null) {
      print('');
      print('⚠️  No version manager detected (SDKMAN!, asdf, winget)');
      print('   Cannot automatically switch Java versions');
      print('');
      _printManualInstructions(requiredVersion);
      return null;
    }

    if (_verbose) {
      print('   Found version manager: ${versionManager.name}');
    }

    // Check if required version is already installed
    final installedVersions = await versionManager.listInstalledJavaVersions();
    final compatibleVersion =
        _findCompatibleVersion(installedVersions, requiredVersion);

    if (compatibleVersion != null) {
      if (_verbose) {
        print('   ✓ Found compatible installed version: $compatibleVersion');
      }

      final javaHome = await versionManager.getJavaHome(compatibleVersion);
      if (javaHome != null) {
        return _buildEnvironment(javaHome);
      }
    }

    // Install if not found and auto-install is enabled
    if (autoInstall) {
      print('');
      print('📥 Java $requiredVersion not found, attempting to install...');

      final installed =
          await versionManager.installJavaVersion(requiredVersion);

      if (installed) {
        final javaHome = await versionManager.getJavaHome(requiredVersion);
        if (javaHome != null) {
          return _buildEnvironment(javaHome);
        }
      } else {
        print('❌ Failed to install Java $requiredVersion');
        _printManualInstructions(requiredVersion);
        throw Exception(
            'Java $requiredVersion is required but could not be installed');
      }
    } else {
      print('');
      print('⚠️  Java $requiredVersion not found');
      _printManualInstructions(requiredVersion);
      throw Exception('Java $requiredVersion is required but not installed');
    }

    return null;
  }

  /// Get current Java version from system
  Future<String?> _getCurrentJavaVersion() async {
    try {
      final result = await Process.run('java', ['-version']);
      final output = (result.stderr as String) + (result.stdout as String);

      // Parse version from output
      // Example: openjdk version "21.0.1" 2023-10-17
      // Example: java version "1.8.0_351"
      final versionMatch = RegExp(r'version "(\d+)\.?(\d*)\.?(\d*)[_\-]?.*?"')
          .firstMatch(output);

      if (versionMatch != null) {
        final major = versionMatch.group(1)!;
        // Handle old Java versions (1.8 -> 8)
        if (major == '1') {
          return versionMatch.group(2);
        }
        return major;
      }
    } catch (e) {
      // java command not found or failed
    }

    return null;
  }

  /// Check if current version is compatible with required version
  bool _isVersionCompatible(String current, String required) {
    try {
      final currentMajor = int.parse(current);
      final requiredMajor = int.parse(required);

      // Java is generally forward compatible within major versions
      // but Kotlin may have upper limits
      return currentMajor <= requiredMajor;
    } catch (e) {
      return false;
    }
  }

  /// Find a compatible version from installed versions
  String? _findCompatibleVersion(List<String> installed, String required) {
    // First try exact match on major version
    for (final version in installed) {
      if (version.startsWith('$required.') ||
          version.startsWith('$required-') ||
          version == required) {
        return version;
      }
    }

    // Try to extract major version and match
    for (final version in installed) {
      final match = RegExp(r'^(\d+)').firstMatch(version);
      if (match != null && match.group(1) == required) {
        return version;
      }
    }

    return null;
  }

  /// Build environment map with JAVA_HOME and PATH
  Map<String, String> _buildEnvironment(String javaHome) {
    final env = Map<String, String>.from(Platform.environment);

    env['JAVA_HOME'] = javaHome;

    // Add Java bin directory to PATH
    final javaBin = p.join(javaHome, 'bin');
    final currentPath = env['PATH'] ?? '';

    if (Platform.isWindows) {
      env['PATH'] = '$javaBin;$currentPath';
    } else {
      env['PATH'] = '$javaBin:$currentPath';
    }

    if (_verbose) {
      print('   ✓ Environment configured:');
      print('     JAVA_HOME=$javaHome');
      print('     PATH=$javaBin:...');
    }

    return env;
  }

  /// Print manual installation instructions
  void _printManualInstructions(String version) {
    print('');
    print('═══════════════════════════════════════════════════════════');
    print('📋 Manual Java Installation Instructions');
    print('═══════════════════════════════════════════════════════════');
    print('');

    if (Platform.isLinux || Platform.isMacOS) {
      print('Option 1: Using SDKMAN! (recommended)');
      print('  1. Install SDKMAN!: https://sdkman.io/install');
      print('  2. Install Java: sdk install java $version-tem');
      print('  3. Set as default: sdk default java $version-tem');
      print('');
      print('Option 2: Using asdf');
      print(
          '  1. Install asdf: https://asdf-vm.com/guide/getting-started.html');
      print('  2. Add Java plugin: asdf plugin-add java');
      print('  3. Install Java: asdf install java temurin-$version');
      print('  4. Set global: asdf global java temurin-$version');
      print('');
    }

    if (Platform.isWindows) {
      print('Option 1: Using winget (Windows 11/10)');
      print('  winget install EclipseAdoptium.Temurin.$version.JDK');
      print('');
      print('Option 2: Manual download');
      print('  Download from: https://adoptium.net/');
      print('');
    }

    if (Platform.isMacOS) {
      print('Option 3: Using Homebrew');
      print('  brew install openjdk@$version');
      print('');
    }

    print('Option ${Platform.isWindows ? "3" : "4"}: Direct download');
    print('  Download from: https://adoptium.net/');
    print('  Or: https://www.oracle.com/java/technologies/downloads/');
    print('');
    print('After installation, verify with: java -version');
    print('═══════════════════════════════════════════════════════════');
    print('');
  }

  /// Validate that a Java installation is working
  Future<bool> validateJavaInstallation(String javaHome) async {
    final javac = Platform.isWindows
        ? p.join(javaHome, 'bin', 'javac.exe')
        : p.join(javaHome, 'bin', 'javac');

    final java = Platform.isWindows
        ? p.join(javaHome, 'bin', 'java.exe')
        : p.join(javaHome, 'bin', 'java');

    if (!await File(javac).exists() || !await File(java).exists()) {
      return false;
    }

    try {
      final result = await Process.run(java, ['-version']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }
}
