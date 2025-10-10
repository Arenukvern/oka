import 'dart:io';

import 'package:path/path.dart' as p;

/// Locates Android SDK tools and validates their availability
class SdkLocator {
  final String? _androidSdkPath;
  final String? _flutterSdkPath;

  SdkLocator({String? androidSdkPath, String? flutterSdkPath})
      : _androidSdkPath = androidSdkPath,
        _flutterSdkPath = flutterSdkPath;

  /// Find Android SDK path
  Future<String> findAndroidSdk() async {
    if (_androidSdkPath != null && await Directory(_androidSdkPath).exists()) {
      return _androidSdkPath;
    }

    // Check ANDROID_HOME environment variable
    final androidHome = Platform.environment['ANDROID_HOME'];
    if (androidHome != null && await Directory(androidHome).exists()) {
      return androidHome;
    }

    // Check ANDROID_SDK_ROOT
    final androidSdkRoot = Platform.environment['ANDROID_SDK_ROOT'];
    if (androidSdkRoot != null && await Directory(androidSdkRoot).exists()) {
      return androidSdkRoot;
    }

    // Check common locations
    final commonPaths = [
      p.join(Platform.environment['HOME'] ?? '', 'Android', 'Sdk'),
      p.join(Platform.environment['HOME'] ?? '', 'Library', 'Android', 'sdk'),
      '/usr/local/android-sdk',
    ];

    for (final path in commonPaths) {
      if (await Directory(path).exists()) {
        return path;
      }
    }

    throw Exception(
      'Android SDK not found. Please set ANDROID_HOME environment variable '
      'or install Android SDK.',
    );
  }

  /// Find Flutter SDK path
  Future<String> findFlutterSdk() async {
    if (_flutterSdkPath != null && await Directory(_flutterSdkPath).exists()) {
      return _flutterSdkPath;
    }

    // Try to run flutter command and get SDK path
    try {
      final result = await Process.run('flutter', ['--version', '--machine']);
      if (result.exitCode == 0) {
        // Parse flutter SDK path from output
        final flutterBin = await Process.run('which', ['flutter']);
        if (flutterBin.exitCode == 0) {
          final binPath = (flutterBin.stdout as String).trim();
          final sdkPath = p.dirname(p.dirname(binPath));
          if (await Directory(sdkPath).exists()) {
            return sdkPath;
          }
        }
      }
    } catch (e) {
      // Flutter not in PATH
    }

    throw Exception(
      'Flutter SDK not found. Please ensure Flutter is installed and in PATH.',
    );
  }

  /// Locate aapt2 tool
  Future<String> findAapt2() async {
    final androidSdk = await findAndroidSdk();
    final buildToolsDir = Directory(p.join(androidSdk, 'build-tools'));

    if (!await buildToolsDir.exists()) {
      throw Exception('build-tools directory not found in Android SDK');
    }

    // Find latest build-tools version
    final versions = await buildToolsDir
        .list()
        .where((e) => e is Directory)
        .map((e) => p.basename(e.path))
        .toList();

    if (versions.isEmpty) {
      throw Exception('No build-tools version found in Android SDK');
    }

    versions.sort((a, b) => b.compareTo(a)); // Reverse sort for latest

    for (final version in versions) {
      final aapt2Path = p.join(androidSdk, 'build-tools', version, 'aapt2');
      if (await File(aapt2Path).exists()) {
        return aapt2Path;
      }
    }

    throw Exception('aapt2 not found in Android SDK build-tools');
  }

  /// Locate d8 tool (DEX compiler for debug)
  Future<String> findD8() async {
    final androidSdk = await findAndroidSdk();
    final buildToolsDir = Directory(p.join(androidSdk, 'build-tools'));

    final versions = await buildToolsDir
        .list()
        .where((e) => e is Directory)
        .map((e) => p.basename(e.path))
        .toList();

    versions.sort((a, b) => b.compareTo(a));

    for (final version in versions) {
      final d8Path = p.join(androidSdk, 'build-tools', version, 'd8');
      if (await File(d8Path).exists()) {
        return d8Path;
      }
    }

    throw Exception('d8 not found in Android SDK build-tools');
  }

  /// Locate r8 tool (DEX compiler with optimization for release)
  ///
  /// Returns null if r8 is not found instead of throwing an exception
  Future<String?> findR8() async {
    final androidSdk = await findAndroidSdk();
    final buildToolsDir = Directory(p.join(androidSdk, 'build-tools'));

    if (await buildToolsDir.exists()) {
      final versions = await buildToolsDir
          .list()
          .where((e) => e is Directory)
          .map((e) => p.basename(e.path))
          .toList();

      versions.sort((a, b) => b.compareTo(a));

      for (final version in versions) {
        final r8Path = p.join(androidSdk, 'build-tools', version, 'r8');
        if (await File(r8Path).exists()) {
          return r8Path;
        }

        // R8 might be a jar file
        final r8JarPath =
            p.join(androidSdk, 'build-tools', version, 'lib', 'r8.jar');
        if (await File(r8JarPath).exists()) {
          return r8JarPath;
        }
      }
    }

    // Check cmdline-tools location
    final cmdlineToolsR8 =
        p.join(androidSdk, 'cmdline-tools', 'latest', 'lib', 'r8.jar');
    if (await File(cmdlineToolsR8).exists()) {
      return cmdlineToolsR8;
    }

    // Not found, return null instead of throwing
    return null;
  }

  /// Locate zipalign tool
  Future<String> findZipalign() async {
    final androidSdk = await findAndroidSdk();
    final buildToolsDir = Directory(p.join(androidSdk, 'build-tools'));

    final versions = await buildToolsDir
        .list()
        .where((e) => e is Directory)
        .map((e) => p.basename(e.path))
        .toList();

    versions.sort((a, b) => b.compareTo(a));

    for (final version in versions) {
      final zipalignPath =
          p.join(androidSdk, 'build-tools', version, 'zipalign');
      if (await File(zipalignPath).exists()) {
        return zipalignPath;
      }
    }

    throw Exception('zipalign not found in Android SDK build-tools');
  }

  /// Locate apksigner tool
  Future<String> findApksigner() async {
    final androidSdk = await findAndroidSdk();
    final buildToolsDir = Directory(p.join(androidSdk, 'build-tools'));

    final versions = await buildToolsDir
        .list()
        .where((e) => e is Directory)
        .map((e) => p.basename(e.path))
        .toList();

    versions.sort((a, b) => b.compareTo(a));

    for (final version in versions) {
      final apksignerPath =
          p.join(androidSdk, 'build-tools', version, 'apksigner');
      if (await File(apksignerPath).exists()) {
        return apksignerPath;
      }
    }

    throw Exception('apksigner not found in Android SDK build-tools');
  }

  /// Locate adb tool
  Future<String> findAdb() async {
    final androidSdk = await findAndroidSdk();
    final adbPath = p.join(androidSdk, 'platform-tools', 'adb');

    if (await File(adbPath).exists()) {
      return adbPath;
    }

    throw Exception('adb not found in Android SDK platform-tools');
  }

  /// Locate kotlinc compiler
  Future<String?> findKotlinc() async {
    // Check if kotlinc is in PATH
    try {
      final result = await Process.run('which', ['kotlinc']);
      if (result.exitCode == 0) {
        return (result.stdout as String).trim();
      }
    } catch (e) {
      // Not in PATH
    }

    // Check KOTLIN_HOME
    final kotlinHome = Platform.environment['KOTLIN_HOME'];
    if (kotlinHome != null) {
      final kotlincPath = p.join(kotlinHome, 'bin', 'kotlinc');
      if (await File(kotlincPath).exists()) {
        return kotlincPath;
      }
    }

    return null; // Kotlin compiler optional
  }

  /// Locate javac compiler
  Future<String> findJavac() async {
    // Check if javac is in PATH
    try {
      final result = await Process.run('which', ['javac']);
      if (result.exitCode == 0) {
        return (result.stdout as String).trim();
      }
    } catch (e) {
      // Not in PATH
    }

    // Check JAVA_HOME
    final javaHome = Platform.environment['JAVA_HOME'];
    if (javaHome != null) {
      final javacPath = p.join(javaHome, 'bin', 'javac');
      if (await File(javacPath).exists()) {
        return javacPath;
      }
    }

    throw Exception('javac not found. Please install JDK and set JAVA_HOME');
  }

  /// Validate all required tools are available
  Future<Map<String, String>> validateTools() async {
    final tools = <String, String>{};

    try {
      tools['android_sdk'] = await findAndroidSdk();
      tools['flutter_sdk'] = await findFlutterSdk();
      tools['aapt2'] = await findAapt2();
      tools['d8'] = await findD8();

      final r8 = await findR8();
      if (r8 != null) {
        tools['r8'] = r8;
      }

      tools['zipalign'] = await findZipalign();
      tools['apksigner'] = await findApksigner();
      tools['adb'] = await findAdb();
      tools['javac'] = await findJavac();

      final kotlinc = await findKotlinc();
      if (kotlinc != null) {
        tools['kotlinc'] = kotlinc;
      }
    } catch (e) {
      rethrow;
    }

    return tools;
  }
}
