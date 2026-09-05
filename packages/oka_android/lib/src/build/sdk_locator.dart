import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:oka_core/src/config/build_context.dart';
import 'java_environment.dart';

/// Locates Android SDK tools and validates their availability
class SdkLocator {
  final String? _androidSdkPath;
  final String? _flutterSdkPath;
  final bool _verbose;

  SdkLocator({
    String? androidSdkPath,
    String? flutterSdkPath,
    bool verbose = false,
  })  : _androidSdkPath = androidSdkPath,
        _flutterSdkPath = flutterSdkPath,
        _verbose = verbose;

  /// Find Android SDK path
  Future<String> findAndroidSdk() async {
    if (_androidSdkPath != null) {
      if (await Directory(_androidSdkPath).exists()) {
        return _androidSdkPath;
      }
      // Explicit override that does not exist — do not silently fall through.
      throw Exception(
        'Android SDK not found at configured path: $_androidSdkPath',
      );
    }

    // Oka-managed install root (preferred for no-Gradle CI / laptop setups)
    final okaSdkEnv = Platform.environment['OKA_ANDROID_SDK'];
    if (okaSdkEnv != null && await Directory(okaSdkEnv).exists()) {
      return okaSdkEnv;
    }

    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final okaManaged = p.join(home, '.oka', 'android-sdk');
    if (home.isNotEmpty && await Directory(okaManaged).exists()) {
      // Prefer if it has packaging tools
      final bt = Directory(p.join(okaManaged, 'build-tools'));
      if (await bt.exists()) {
        return okaManaged;
      }
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
      if (home.isNotEmpty) okaManaged,
    ];

    for (final path in commonPaths) {
      if (await Directory(path).exists()) {
        return path;
      }
    }

    throw Exception(
      'Android SDK not found. Run: oka get android-sdk\n'
      'Or set ANDROID_HOME / OKA_ANDROID_SDK.',
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
    // First check oka's managed Kotlin installation
    final homeDir = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (homeDir.isNotEmpty) {
      final okaCacheDir = p.join(homeDir, '.oka', 'tools');
      final kotlinDir = Directory(okaCacheDir);

      if (await kotlinDir.exists()) {
        // Look for any kotlin-* directory
        await for (final entity in kotlinDir.list()) {
          if (entity is Directory &&
              p.basename(entity.path).startsWith('kotlin-')) {
            final kotlincPath = p.join(entity.path, 'bin', 'kotlinc');
            if (await File(kotlincPath).exists()) {
              return kotlincPath;
            }
          }
        }
      }
    }

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

  /// Find Kotlin standard library JAR
  /// Returns the path to kotlin-stdlib.jar needed for Kotlin compilation
  Future<String?> findKotlinStdlib() async {
    final kotlinc = await findKotlinc();
    if (kotlinc == null) {
      return null;
    }

    // kotlinc is typically at: <kotlin-home>/bin/kotlinc
    // stdlib is at: <kotlin-home>/lib/kotlin-stdlib.jar
    final kotlincDir = p.dirname(kotlinc); // bin directory
    final kotlinHome = p.dirname(kotlincDir); // kotlin home
    final libDir = p.join(kotlinHome, 'lib');

    // Look for kotlin-stdlib.jar
    final stdlibPath = p.join(libDir, 'kotlin-stdlib.jar');
    if (await File(stdlibPath).exists()) {
      return stdlibPath;
    }

    // If not found, try to find any kotlin-stdlib*.jar in lib directory
    final libDirectory = Directory(libDir);
    if (await libDirectory.exists()) {
      await for (final entity in libDirectory.list()) {
        if (entity is File &&
            p.basename(entity.path).startsWith('kotlin-stdlib')) {
          return entity.path;
        }
      }
    }

    return null;
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
    final home = Platform.environment['HOME'] ?? '';

    // Check oka cache
    final okaCacheDir = p.join(home, '.oka', 'cache', 'androidx');
    final cachedJar = p.join(okaCacheDir, 'annotation-jvm-1.9.1.jar');
    if (await File(cachedJar).exists()) {
      return cachedJar;
    }

    // Download from Google Maven
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

  /// Locate AndroidX lifecycle-common JAR
  ///
  /// Downloads from Google Maven if not found in oka cache
  Future<String> findAndroidXLifecycle() async {
    final home = Platform.environment['HOME'] ?? '';

    // Check oka cache
    final okaCacheDir = p.join(home, '.oka', 'cache', 'androidx');
    final cachedJar = p.join(okaCacheDir, 'lifecycle-common-jvm-2.8.7.jar');
    if (await File(cachedJar).exists()) {
      return cachedJar;
    }

    // Download from Google Maven
    if (_promptUserForDownload('androidx.lifecycle:lifecycle-common')) {
      print(
          '📥 Downloading AndroidX lifecycle-common JAR from Google Maven...');
      final downloadedPath = await _downloadAndroidXLifecycle('2.8.7');
      print('✅ Downloaded to: $downloadedPath');
      return downloadedPath;
    }

    throw Exception(
      'AndroidX lifecycle-common JAR not found. '
      'Download from https://maven.google.com/androidx/lifecycle/lifecycle-common-jvm/',
    );
  }

  /// Locate AndroidX lifecycle-runtime JAR
  ///
  /// Downloads from Google Maven if not found in oka cache
  Future<String> findAndroidXLifecycleRuntime() async {
    final home = Platform.environment['HOME'] ?? '';

    // Check oka cache
    final okaCacheDir = p.join(home, '.oka', 'cache', 'androidx');
    final cachedJar = p.join(okaCacheDir, 'lifecycle-runtime-2.8.7.jar');
    if (await File(cachedJar).exists()) {
      return cachedJar;
    }

    // Download from Google Maven
    if (_promptUserForDownload('androidx.lifecycle:lifecycle-runtime')) {
      print(
          '📥 Downloading AndroidX lifecycle-runtime JAR from Google Maven...');
      final downloadedPath = await _downloadAndroidXLifecycleRuntime('2.8.7');
      print('✅ Downloaded to: $downloadedPath');
      return downloadedPath;
    }

    throw Exception(
      'AndroidX lifecycle-runtime JAR not found. '
      'Download from https://maven.google.com/androidx/lifecycle/lifecycle-runtime/',
    );
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

    final jarFileName = 'annotation-jvm-$version.jar';
    final jarPath = p.join(cacheDir, jarFileName);

    // If already exists, return it
    if (await File(jarPath).exists()) {
      return jarPath;
    }

    final url =
        'https://maven.google.com/androidx/annotation/annotation-jvm/$version/$jarFileName';

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

  /// Download AndroidX lifecycle-common JAR from Google Maven repository
  Future<String> _downloadAndroidXLifecycle(String version) async {
    final home = Platform.environment['HOME'] ?? '';
    final cacheDir = p.join(home, '.oka', 'cache', 'androidx');
    await Directory(cacheDir).create(recursive: true);

    final jarFileName = 'lifecycle-common-jvm-$version.jar';
    final jarPath = p.join(cacheDir, jarFileName);

    // If already exists, return it
    if (await File(jarPath).exists()) {
      return jarPath;
    }

    final url =
        'https://maven.google.com/androidx/lifecycle/lifecycle-common-jvm/$version/$jarFileName';

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

  /// Download AndroidX lifecycle-runtime JAR from Google Maven repository
  ///
  /// Downloads the AAR and extracts classes.jar from it since the Android
  /// classes are packaged in AAR format, not as standalone JARs
  Future<String> _downloadAndroidXLifecycleRuntime(String version) async {
    final home = Platform.environment['HOME'] ?? '';
    final cacheDir = p.join(home, '.oka', 'cache', 'androidx');
    await Directory(cacheDir).create(recursive: true);

    final jarFileName = 'lifecycle-runtime-$version.jar';
    final jarPath = p.join(cacheDir, jarFileName);

    // If already exists, return it
    if (await File(jarPath).exists()) {
      return jarPath;
    }

    // Download AAR file
    final aarFileName = 'lifecycle-runtime-$version.aar';
    final aarPath = p.join(cacheDir, aarFileName);
    final url =
        'https://maven.google.com/androidx/lifecycle/lifecycle-runtime/$version/$aarFileName';

    print('   URL: $url');
    print('   Downloading AAR...');

    try {
      // Download AAR
      final downloadResult = await Process.run(
        'curl',
        [
          '-L', // Follow redirects
          '-f', // Fail on HTTP errors
          '-o',
          aarPath,
          '--progress-bar',
          url,
        ],
        stdoutEncoding: null,
        stderrEncoding: null,
      );

      if (downloadResult.exitCode != 0) {
        final stderr = downloadResult.stderr != null
            ? String.fromCharCodes(downloadResult.stderr as List<int>)
            : 'Unknown error';
        throw Exception(
            'Download failed (exit code ${downloadResult.exitCode}): $stderr');
      }

      // Extract classes.jar from AAR (AAR is just a ZIP file)
      print('   Extracting classes.jar from AAR...');
      final extractResult = await Process.run(
        'unzip',
        ['-j', aarPath, 'classes.jar', '-d', cacheDir],
      );

      if (extractResult.exitCode != 0) {
        throw Exception(
            'Failed to extract classes.jar: ${extractResult.stderr}');
      }

      // Rename extracted classes.jar to our target name
      final extractedJar = p.join(cacheDir, 'classes.jar');
      await File(extractedJar).rename(jarPath);

      // Clean up AAR file
      await File(aarPath).delete();

      // Validate extracted JAR
      final jarFile = File(jarPath);
      if (!await jarFile.exists()) {
        throw Exception('Extracted JAR not found at: $jarPath');
      }

      final fileSize = await jarFile.length();
      print('   File size: ${(fileSize / 1024).toStringAsFixed(2)} KB');

      if (fileSize < 1000) {
        // JAR should be at least 1KB
        await jarFile.delete();
        throw Exception('Extracted file is too small (possibly invalid)');
      }

      return jarPath;
    } catch (e) {
      // Clean up partial downloads
      final jarFile = File(jarPath);
      if (await jarFile.exists()) {
        await jarFile.delete();
      }
      final aarFile = File(aarPath);
      if (await aarFile.exists()) {
        await aarFile.delete();
      }
      rethrow;
    }
  }

  /// Resolve Java environment for Kotlin compilation
  ///
  /// Reads required Java version from [BuildContext] and ensures
  /// the correct Java version is available for kotlinc
  ///
  /// Returns environment variables map to use for Process.run calls,
  /// or null if system default Java should be used
  Future<Map<String, String>?> resolveJavaForKotlin(BuildContext ctx) async {
    final requiredJavaVersion = ctx.config.android.requiredJavaVersion;

    final javaEnv = JavaEnvironment(verbose: _verbose);

    try {
      final env = await javaEnv.resolveJavaEnvironment(
        requiredJavaVersion,
        autoInstall: true,
      );

      return env;
    } catch (e) {
      print('❌ Failed to resolve Java environment: $e');
      rethrow;
    }
  }

  /// Tools required to **package** an APK (no device install).
  ///
  /// Does **not** require `adb` / platform-tools — missing adb must not abort
  /// the no-Gradle build pipeline.
  Future<Map<String, String>> validatePackagingTools() async {
    final tools = <String, String>{};

    tools['android_sdk'] = await findAndroidSdk();
    tools['flutter_sdk'] = await findFlutterSdk();
    tools['aapt2'] = await findAapt2();
    tools['d8'] = await findD8();
    tools['zipalign'] = await findZipalign();
    tools['apksigner'] = await findApksigner();
    tools['javac'] = await findJavac();

    final r8 = await findR8();
    if (r8 != null) {
      tools['r8'] = r8;
    }

    final kotlinc = await findKotlinc();
    if (kotlinc != null) {
      tools['kotlinc'] = kotlinc;
    }

    return tools;
  }

  /// Validate tools for doctor / full environment checks.
  ///
  /// Includes optional `adb` when present; packaging validation is
  /// [validatePackagingTools].
  Future<Map<String, String>> validateTools({bool requireAdb = false}) async {
    final tools = await validatePackagingTools();

    try {
      tools['adb'] = await findAdb();
    } catch (e) {
      if (requireAdb) {
        rethrow;
      }
      // Optional for packaging-only flows
      if (_verbose) {
        print('⚠️  adb not found (optional for APK packaging): $e');
      }
    }

    return tools;
  }
}
