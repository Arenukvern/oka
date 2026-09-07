import 'dart:io';
import 'package:oka_core/oka_core.dart';

import 'package:path/path.dart' as p;

import 'java_environment.dart';

/// Locates Android SDK tools and validates their availability.
///
/// Resolution order (first hit wins): an explicitly provided path, the
/// `OKA_ANDROID_SDK` environment variable, an oka-managed SDK under
/// `~/.oka/android-sdk` (install with `oka get android-sdk`), then the
/// standard `ANDROID_HOME` / `ANDROID_SDK_ROOT` locations.
///
/// Steps receive a configured locator via their constructors; the default
/// pipeline wires one for all tool steps.
///
/// AndroidX JAR provisioning goes through the shared [ArtifactStore]
/// (ADR-0013): legacy downloads under `~/.oka/cache/androidx` still resolve
/// (read-only), new downloads land in the store (`OKA_CACHE`-pointable) and
/// are automatic — never interactive, no stdin in the build path.
class SdkLocator {

  SdkLocator({
    this._androidSdkPath,
    this._flutterSdkPath,
    this._verbose = false,
    final ArtifactStore? store,
  })  : _store = store ?? LocalArtifactStore();
  final String? _androidSdkPath;
  final String? _flutterSdkPath;
  final bool _verbose;
  final ArtifactStore _store;

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
        .where((final e) => e is Directory)
        .map((final e) => p.basename(e.path))
        .toList();

    if (versions.isEmpty) {
      throw Exception('No build-tools version found in Android SDK');
    }

    versions.sort((final a, final b) => b.compareTo(a)); // Reverse sort for latest

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
        .where((final e) => e is Directory)
        .map((final e) => p.basename(e.path))
        .toList();

    versions.sort((final a, final b) => b.compareTo(a));

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
          .where((final e) => e is Directory)
          .map((final e) => p.basename(e.path))
          .toList();

      versions.sort((final a, final b) => b.compareTo(a));

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
        .where((final e) => e is Directory)
        .map((final e) => p.basename(e.path))
        .toList();

    versions.sort((final a, final b) => b.compareTo(a));

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
        .where((final e) => e is Directory)
        .map((final e) => p.basename(e.path))
        .toList();

    versions.sort((final a, final b) => b.compareTo(a));

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
  Future<String> findAndroidXAnnotations() => _androidXJar(
        name: 'annotation-jvm',
        version: '1.9.1',
        legacyFileName: 'annotation-jvm-1.9.1.jar',
        miss: (final tmpDir) => _downloadAndroidXJar(
          url:
              'https://maven.google.com/androidx/annotation/annotation-jvm/1.9.1/annotation-jvm-1.9.1.jar',
          fileName: 'annotation-jvm-1.9.1.jar',
          tmpDir: tmpDir,
        ),
      );

  /// Locate AndroidX lifecycle-common JAR
  ///
  /// Downloads from Google Maven through the artifact store when missing.
  Future<String> findAndroidXLifecycle() => _androidXJar(
        name: 'lifecycle-common-jvm',
        version: '2.8.7',
        legacyFileName: 'lifecycle-common-jvm-2.8.7.jar',
        miss: (final tmpDir) => _downloadAndroidXJar(
          url:
              'https://maven.google.com/androidx/lifecycle/lifecycle-common-jvm/2.8.7/lifecycle-common-jvm-2.8.7.jar',
          fileName: 'lifecycle-common-jvm-2.8.7.jar',
          tmpDir: tmpDir,
        ),
      );

  /// Locate AndroidX lifecycle-runtime JAR
  ///
  /// Downloads the AAR from Google Maven through the artifact store and
  /// extracts `classes.jar` from it (Android classes ship in AAR packaging).
  Future<String> findAndroidXLifecycleRuntime() => _androidXJar(
        name: 'lifecycle-runtime',
        version: '2.8.7',
        legacyFileName: 'lifecycle-runtime-2.8.7.jar',
        miss: (final tmpDir) async {
          const version = '2.8.7';
          final aarFile = await _downloadAndroidXJar(
            url:
                'https://maven.google.com/androidx/lifecycle/lifecycle-runtime/2.8.7/lifecycle-runtime-2.8.7.aar',
            fileName: 'lifecycle-runtime-$version.aar',
            tmpDir: tmpDir,
          );
          print('   Extracting classes.jar from AAR...');
          final extractResult = await Process.run(
            'unzip',
            ['-j', aarFile.path, 'classes.jar', '-d', tmpDir],
          );
          if (extractResult.exitCode != 0) {
            throw Exception(
                'Failed to extract classes.jar: ${extractResult.stderr}');
          }
          final jarFile = File(p.join(tmpDir, 'classes.jar'))
              .rename(p.join(tmpDir, 'lifecycle-runtime-$version.jar'));
          await aarFile.delete();
          return jarFile;
        },
      );

  /// Resolves an AndroidX JAR: legacy flat cache (`~/.oka/cache/androidx`)
  /// is honored read-only, otherwise the artifact store fetches via [miss]
  /// exactly once and stores under
  /// `<storeRoot>/androidx/<name>/<version>-<hash>/<platform>/`.
  Future<String> _androidXJar({
    required final String name,
    required final String version,
    required final String legacyFileName,
    required final Future<File> Function(String tmpDir) miss,
  }) async {
    final home = Platform.environment['HOME'] ?? '';

    // Legacy cache (pre-store layout) — read-only, still resolves.
    final legacyJar = File(
      p.join(home, '.oka', 'cache', 'androidx', legacyFileName),
    );
    if (await legacyJar.exists()) {
      return legacyJar.path;
    }

    print('📥 Downloading AndroidX $name $version from Google Maven...');
    final key = ContentKey.compute(
      category: 'androidx',
      name: name,
      version: version,
      inputs: ['google-maven:$name:$version'],
    );
    final tmp = await Directory.systemTemp.createTemp('oka_androidx_');
    try {
      final stored = await _store.fetch(key, () => miss(tmp.path));
      print('   File size: ${(await stored.length() / 1024).toStringAsFixed(2)} KB');
      print('✅ Cached at: ${stored.path}');
      return stored.path;
    } finally {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // best-effort temp cleanup
      }
    }
  }

  /// Downloads [url] with curl into [tmpDir]/[fileName], validating the
  /// payload is a real artifact (≥ 1 KB) — partial downloads are removed.
  Future<File> _downloadAndroidXJar({
    required final String url,
    required final String fileName,
    required final String tmpDir,
  }) async {
    final target = File(p.join(tmpDir, fileName));
    print('   URL: $url');
    print('   Target: ${target.path}');

    final result = await Process.run(
      'curl',
      [
        '-L', // Follow redirects
        '-f', // Fail on HTTP errors
        '-o',
        target.path,
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
      throw Exception('Download failed (exit code ${result.exitCode}): $stderr');
    }

    if (!await target.exists()) {
      throw Exception('Downloaded file not found at: ${target.path}');
    }

    final fileSize = await target.length();
    if (fileSize < 1000) {
      // JAR should be at least 1KB
      await target.delete();
      throw Exception('Downloaded file is too small (possibly invalid)');
    }
    return target;
  }

  /// Resolve Java environment for Kotlin compilation
  ///
  /// Reads required Java version from [BuildContext] and ensures
  /// the correct Java version is available for kotlinc
  ///
  /// Returns environment variables map to use for Process.run calls,
  /// or null if system default Java should be used
  Future<Map<String, String>?> resolveJavaForKotlin(final BuildContext ctx) async {
    final requiredJavaVersion = ctx.config.android.requiredJavaVersion;

    final javaEnv = JavaEnvironment(verbose: _verbose);

    try {
      final env = await javaEnv.resolveJavaEnvironment(
        requiredJavaVersion,
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
  Future<Map<String, String>> validateTools({final bool requireAdb = false}) async {
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
