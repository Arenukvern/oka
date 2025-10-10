import 'dart:io';

import 'package:path/path.dart' as p;

/// {@template version_manager}
/// Abstract interface for Java version managers
///
/// Provides methods to detect, install, and switch between Java versions
/// using system version managers like SDKMAN!, asdf, or winget
/// {@endtemplate}
abstract class VersionManager {
  /// {@macro version_manager}
  const VersionManager();

  /// Check if this version manager is available on the system
  Future<bool> isAvailable();

  /// Get list of installed Java versions
  Future<List<String>> listInstalledJavaVersions();

  /// Install a specific Java version
  Future<bool> installJavaVersion(String version);

  /// Get JAVA_HOME path for a specific version
  Future<String?> getJavaHome(String version);

  /// Get the name of this version manager
  String get name;

  /// Detect the best available version manager for the current system
  static Future<VersionManager?> detectBestVersionManager() async {
    final managers = <VersionManager>[
      if (!Platform.isWindows) ...[
        const SDKMANVersionManager(),
        const AsdfVersionManager(),
      ],
      if (Platform.isWindows) const WingetVersionManager(),
    ];

    for (final manager in managers) {
      if (await manager.isAvailable()) {
        return manager;
      }
    }

    return null;
  }
}

/// SDKMAN! version manager implementation for Linux/macOS
class SDKMANVersionManager extends VersionManager {
  const SDKMANVersionManager();

  @override
  String get name => 'SDKMAN!';

  @override
  Future<bool> isAvailable() async {
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return false;

    final sdkmanDir = p.join(home, '.sdkman');
    return await Directory(sdkmanDir).exists();
  }

  @override
  Future<List<String>> listInstalledJavaVersions() async {
    final home = Platform.environment['HOME'] ?? '';
    final candidatesDir = p.join(home, '.sdkman', 'candidates', 'java');

    if (!await Directory(candidatesDir).exists()) {
      return [];
    }

    final versions = <String>[];
    await for (final entity in Directory(candidatesDir).list()) {
      if (entity is Directory) {
        final version = p.basename(entity.path);
        if (version != 'current') {
          versions.add(version);
        }
      }
    }

    return versions;
  }

  @override
  Future<bool> installJavaVersion(String version) async {
    print('📥 Installing Java $version via SDKMAN!...');

    // SDKMAN! requires bash and interactive mode, so we need to source it
    final home = Platform.environment['HOME'] ?? '';
    final sdkmanInit = p.join(home, '.sdkman', 'bin', 'sdkman-init.sh');

    if (!await File(sdkmanInit).exists()) {
      print('❌ SDKMAN! init script not found');
      return false;
    }

    // Find appropriate Java identifier for SDKMAN!
    // Convert simple version (like "21") to SDKMAN! identifier
    final identifier = await _findSdkmanJavaIdentifier(version);
    if (identifier == null) {
      print('❌ Could not find Java $version in SDKMAN! repository');
      return false;
    }

    print('   Installing: $identifier');

    // Run sdk install command via bash
    final result = await Process.run(
      'bash',
      [
        '-c',
        'source $sdkmanInit && sdk install java $identifier',
      ],
      environment: {
        ...Platform.environment,
        'SDKMAN_DIR': p.join(home, '.sdkman'),
      },
    );

    if (result.exitCode == 0) {
      print('✅ Java $version installed successfully');
      return true;
    } else {
      print('❌ Failed to install Java $version');
      print('   ${result.stderr}');
      return false;
    }
  }

  @override
  Future<String?> getJavaHome(String version) async {
    final home = Platform.environment['HOME'] ?? '';
    final candidatesDir = p.join(home, '.sdkman', 'candidates', 'java');

    if (!await Directory(candidatesDir).exists()) {
      return null;
    }

    // Try exact match first
    final exactPath = p.join(candidatesDir, version);
    if (await Directory(exactPath).exists()) {
      return exactPath;
    }

    // Try to find version that starts with the requested version number
    await for (final entity in Directory(candidatesDir).list()) {
      if (entity is Directory) {
        final basename = p.basename(entity.path);
        if (basename.startsWith('$version.') ||
            basename.startsWith('$version-')) {
          return entity.path;
        }
      }
    }

    return null;
  }

  /// Find SDKMAN! Java identifier for a given version
  Future<String?> _findSdkmanJavaIdentifier(String version) async {
    final home = Platform.environment['HOME'] ?? '';
    final sdkmanInit = p.join(home, '.sdkman', 'bin', 'sdkman-init.sh');

    // List available Java versions from SDKMAN!
    final result = await Process.run(
      'bash',
      [
        '-c',
        'source $sdkmanInit && sdk list java',
      ],
      environment: {
        ...Platform.environment,
        'SDKMAN_DIR': p.join(home, '.sdkman'),
      },
    );

    if (result.exitCode != 0) {
      return null;
    }

    final output = result.stdout as String;
    final lines = output.split('\n');

    // Parse SDKMAN! output to find matching version
    // Look for lines containing the version number
    for (final line in lines) {
      if (line.contains('$version.') || line.contains('$version-')) {
        // Extract identifier from line (typically first column)
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.isNotEmpty) {
          final identifier = parts[0];
          if (identifier.isNotEmpty && !identifier.startsWith('|')) {
            return identifier;
          }
        }
      }
    }

    // Fallback: try common patterns
    final patterns = [
      '$version-tem',
      '$version-open',
      '$version.0-tem',
      '$version.0-open',
    ];

    for (final pattern in patterns) {
      if (output.contains(pattern)) {
        return pattern;
      }
    }

    return null;
  }
}

/// asdf version manager implementation for Linux/macOS
class AsdfVersionManager extends VersionManager {
  const AsdfVersionManager();

  @override
  String get name => 'asdf';

  @override
  Future<bool> isAvailable() async {
    try {
      final result = await Process.run('which', ['asdf']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<List<String>> listInstalledJavaVersions() async {
    try {
      final result = await Process.run('asdf', ['list', 'java']);

      if (result.exitCode != 0) {
        return [];
      }

      final output = result.stdout as String;
      final versions = output
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty && !line.startsWith('*'))
          .map((line) => line.replaceAll('*', '').trim())
          .toList();

      return versions;
    } catch (e) {
      return [];
    }
  }

  @override
  Future<bool> installJavaVersion(String version) async {
    print('📥 Installing Java $version via asdf...');

    // Ensure Java plugin is installed
    await Process.run('asdf', ['plugin-add', 'java']);

    // Find available version
    final identifier = await _findAsdfJavaIdentifier(version);
    if (identifier == null) {
      print('❌ Could not find Java $version in asdf repository');
      return false;
    }

    print('   Installing: $identifier');

    final result = await Process.run('asdf', ['install', 'java', identifier]);

    if (result.exitCode == 0) {
      print('✅ Java $version installed successfully');
      return true;
    } else {
      print('❌ Failed to install Java $version');
      print('   ${result.stderr}');
      return false;
    }
  }

  @override
  Future<String?> getJavaHome(String version) async {
    try {
      final home = Platform.environment['HOME'] ?? '';
      final asdfDir =
          Platform.environment['ASDF_DATA_DIR'] ?? p.join(home, '.asdf');

      final installsDir = p.join(asdfDir, 'installs', 'java');

      if (!await Directory(installsDir).exists()) {
        return null;
      }

      // Try exact match
      final exactPath = p.join(installsDir, version);
      if (await Directory(exactPath).exists()) {
        return exactPath;
      }

      // Try to find version that starts with requested version
      await for (final entity in Directory(installsDir).list()) {
        if (entity is Directory) {
          final basename = p.basename(entity.path);
          if (basename.startsWith('$version.') ||
              basename.startsWith('$version-')) {
            return entity.path;
          }
        }
      }
    } catch (e) {
      // Error accessing asdf directories
    }

    return null;
  }

  /// Find asdf Java identifier for a given version
  Future<String?> _findAsdfJavaIdentifier(String version) async {
    try {
      final result = await Process.run('asdf', ['list-all', 'java']);

      if (result.exitCode != 0) {
        return null;
      }

      final output = result.stdout as String;
      final lines = output.split('\n');

      // Find matching version
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.startsWith('$version.') ||
            trimmed.startsWith('$version-')) {
          return trimmed;
        }
      }

      // Try common patterns
      final patterns = [
        'temurin-$version',
        'openjdk-$version',
        'adoptopenjdk-$version',
      ];

      for (final pattern in patterns) {
        for (final line in lines) {
          if (line.trim().startsWith(pattern)) {
            return line.trim();
          }
        }
      }
    } catch (e) {
      // Error running asdf
    }

    return null;
  }
}

/// winget version manager implementation for Windows
class WingetVersionManager extends VersionManager {
  const WingetVersionManager();

  @override
  String get name => 'winget';

  @override
  Future<bool> isAvailable() async {
    try {
      final result = await Process.run('winget', ['--version']);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<List<String>> listInstalledJavaVersions() async {
    try {
      final result = await Process.run('winget', ['list', '--name', 'Java']);

      if (result.exitCode != 0) {
        return [];
      }

      final output = result.stdout as String;
      final versions = <String>[];

      // Parse winget output to extract installed Java versions
      final lines = output.split('\n');
      for (final line in lines) {
        if (line.contains('Java') && line.contains('JDK')) {
          // Extract version number from line
          final match = RegExp(r'\b(\d+)\.?\d*\.?\d*').firstMatch(line);
          if (match != null) {
            versions.add(match.group(1)!);
          }
        }
      }

      return versions.toSet().toList()..sort();
    } catch (e) {
      return [];
    }
  }

  @override
  Future<bool> installJavaVersion(String version) async {
    print('📥 Installing Java $version via winget...');

    // Determine package ID
    final packageId = _getWingetJavaPackageId(version);

    print('   Installing: $packageId');

    final result = await Process.run(
      'winget',
      ['install', '--id', packageId, '--silent'],
      runInShell: true,
    );

    if (result.exitCode == 0) {
      print('✅ Java $version installed successfully');
      print(
          '   You may need to restart your terminal for changes to take effect');
      return true;
    } else {
      print('❌ Failed to install Java $version');
      print('   ${result.stderr}');
      return false;
    }
  }

  @override
  Future<String?> getJavaHome(String version) async {
    // On Windows, Java installations are typically in Program Files
    final programFiles =
        Platform.environment['ProgramFiles'] ?? 'C:\\Program Files';
    final programFilesX86 =
        Platform.environment['ProgramFiles(x86)'] ?? 'C:\\Program Files (x86)';

    final possiblePaths = [
      p.join(programFiles, 'Java', 'jdk-$version'),
      p.join(programFiles, 'Java', 'jdk$version'),
      p.join(programFiles, 'Eclipse Adoptium', 'jdk-$version'),
      p.join(programFiles, 'Eclipse Adoptium', 'jdk-$version-hotspot'),
      p.join(programFilesX86, 'Java', 'jdk-$version'),
      p.join(programFilesX86, 'Java', 'jdk$version'),
    ];

    for (final path in possiblePaths) {
      if (await Directory(path).exists()) {
        return path;
      }
    }

    return null;
  }

  /// Get winget package ID for Java version
  String _getWingetJavaPackageId(String version) {
    // Use Eclipse Temurin (Adoptium) as default
    // These are well-maintained and widely compatible
    return 'EclipseAdoptium.Temurin.$version.JDK';
  }
}
