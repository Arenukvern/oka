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

  /// Locate Flutter embedding JAR
  Future<String> findFlutterJar() async {
    final flutterSdk = await findFlutterSdk();

    // Try multiple possible locations in Flutter SDK cache
    final possiblePaths = [
      p.join(flutterSdk, 'bin', 'cache', 'artifacts', 'engine', 'android-x64',
          'flutter.jar'),
      p.join(flutterSdk, 'bin', 'cache', 'artifacts', 'engine', 'android-arm',
          'flutter.jar'),
      p.join(flutterSdk, 'bin', 'cache', 'artifacts', 'engine', 'android-arm64',
          'flutter.jar'),
      p.join(flutterSdk, 'bin', 'cache', 'artifacts', 'engine', 'android',
          'flutter.jar'),
    ];

    for (final path in possiblePaths) {
      if (await File(path).exists()) {
        return path;
      }
    }

    throw Exception(
      'Flutter embedding JAR not found. Please run "flutter precache" to download required artifacts.',
    );
  }

  /// Locate AndroidX annotation JAR
  Future<String> findAndroidXAnnotations() async {
    // Check Gradle cache first
    final home = Platform.environment['HOME'] ?? '';
    final gradleCacheDir = p.join(home, '.gradle', 'caches', 'modules-2',
        'files-2.1', 'androidx.annotation', 'annotation');

    if (await Directory(gradleCacheDir).exists()) {
      // Find the latest version directory
      final versions = await Directory(gradleCacheDir)
          .list()
          .where((e) => e is Directory)
          .map((e) => p.basename(e.path))
          .toList();

      if (versions.isNotEmpty) {
        versions.sort((a, b) => b.compareTo(a)); // Reverse sort for latest

        for (final version in versions) {
          final versionDir = p.join(gradleCacheDir, version);
          final hashDirs = await Directory(versionDir)
              .list()
              .where((e) => e is Directory)
              .toList();

          for (final hashDir in hashDirs) {
            final jarPath = p.join(hashDir.path, 'annotation-$version.jar');
            if (await File(jarPath).exists()) {
              return jarPath;
            }
          }
        }
      }
    }

    // Check oka cache
    final okaCacheDir = p.join(home, '.oka', 'cache', 'androidx');
    final cachedJar = p.join(okaCacheDir, 'annotation-1.9.1.jar');
    if (await File(cachedJar).exists()) {
      return cachedJar;
    }

    // Fallback: Check Flutter's local Maven repository
    final flutterSdk = await findFlutterSdk();
    final flutterMavenDir =
        p.join(flutterSdk, 'bin', 'cache', 'artifacts', 'engine', 'androidx');

    if (await Directory(flutterMavenDir).exists()) {
      final annotationJar =
          await _findFileRecursive(flutterMavenDir, 'annotation-', '.jar');
      if (annotationJar != null) {
        return annotationJar;
      }
    }

    // If not found, try to download from Android SDK (if available)
    final androidSdk = await findAndroidSdk();
    final androidxDir = p.join(androidSdk, 'extras', 'androidx', 'annotation');

    if (await Directory(androidxDir).exists()) {
      final annotationJar =
          await _findFileRecursive(androidxDir, 'annotation-', '.jar');
      if (annotationJar != null) {
        return annotationJar;
      }
    }

    // Not found - prompt user to download
    if (_promptUserForDownload('androidx.annotation:annotation')) {
      print('📥 Downloading AndroidX annotation JAR from Google Maven...');
      final downloadedPath = await _downloadAndroidXAnnotations('1.9.1');
      print('✅ Downloaded to: $downloadedPath');
      return downloadedPath;
    }

    throw Exception(
      'AndroidX annotation JAR not found. Please ensure you have built a Flutter Android app at least once, '
      'or manually download androidx.annotation:annotation from https://maven.google.com',
    );
  }

  /// Helper to find a file recursively in a directory
  Future<String?> _findFileRecursive(
      String dirPath, String prefix, String extension) async {
    final directory = Directory(dirPath);
    if (!await directory.exists()) {
      return null;
    }

    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) {
        final basename = p.basename(entity.path);
        if (basename.startsWith(prefix) && basename.endsWith(extension)) {
          return entity.path;
        }
      }
    }

    return null;
  }

  /// Prompt user for permission to download a package
  bool _promptUserForDownload(String packageName) {
    stdout.write('\n⚠️  $packageName not found locally.\n'
        '📦 Download from Google Maven? (y/n): ');
    final response = stdin.readLineSync()?.trim().toLowerCase();
    return response == 'y' || response == 'yes';
  }

  /// Download AndroidX annotation JAR from Google Maven repository
  Future<String> _downloadAndroidXAnnotations(String version) async {
    final home = Platform.environment['HOME'] ?? '';
    final cacheDir = p.join(home, '.oka', 'cache', 'androidx');
    await Directory(cacheDir).create(recursive: true);

    final jarFileName = 'annotation-$version.jar';
    final jarPath = p.join(cacheDir, jarFileName);

    // If already exists, return it
    if (await File(jarPath).exists()) {
      return jarPath;
    }

    final url =
        'https://maven.google.com/androidx/annotation/annotation/$version/$jarFileName';

    print('   URL: $url');
    print('   Target: $jarPath');

    try {
      // Use curl to download with verbose output
      final result = await Process.run(
        'curl',
        [
          '-L', // Follow redirects
          '-f', // Fail on HTTP errors
          '-o',
          jarPath,
          '--progress-bar',
          url,
        ],
        stdoutEncoding: null,
        stderrEncoding: null,
      );

      if (result.exitCode != 0) {
        final stderr = result.stderr != null
            ? String.fromCharCodes(result.stderr as List<int>)
            : 'Unknown error';
        throw Exception(
            'Download failed (exit code ${result.exitCode}): $stderr');
      }

      // Validate downloaded file
      final jarFile = File(jarPath);
      if (!await jarFile.exists()) {
        throw Exception('Downloaded file not found at: $jarPath');
      }

      final fileSize = await jarFile.length();
      print('   File size: ${(fileSize / 1024).toStringAsFixed(2)} KB');

      if (fileSize < 1000) {
        // JAR should be at least 1KB
        await jarFile.delete();
        throw Exception('Downloaded file is too small (possibly invalid)');
      }

      return jarPath;
    } catch (e) {
      // Clean up partial download
      final jarFile = File(jarPath);
      if (await jarFile.exists()) {
        await jarFile.delete();
      }
      rethrow;
    }
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
