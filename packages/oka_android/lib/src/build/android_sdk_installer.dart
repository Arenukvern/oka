import 'dart:io';

import 'package:path/path.dart' as p;

/// Default root for oka-managed Android SDK installs: `~/.oka/android-sdk`.
String defaultOkaAndroidSdkRoot() {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '';
  return p.join(home, '.oka', 'android-sdk');
}

/// Marker file written into oka-managed SDK roots so cleanup is safe.
const kOkaSdkMarkerName = '.oka_managed_sdk';

/// Packages required for no-Gradle APK packaging (adb optional).
List<String> packagingSdkPackages({
  // 35+ recommended: d8 34 NPE on Flutter embedding under modern JDKs
  final String buildTools = '35.0.0',
  final String platformApi = '34',
  final List<String> extraPlatformApis = const ['35', '36'],
}) {
  final platforms = <String>{
    'platforms;android-$platformApi',
    for (final api in extraPlatformApis) 'platforms;android-$api',
  };
  return [
    'cmdline-tools;latest',
    'build-tools;$buildTools',
    ...platforms,
    // platform-tools optional for packaging but useful for install/run
    'platform-tools',
  ];
}

/// Command-line tools zip URL for the current host OS/arch.
String commandLineToolsDownloadUrl({
  final String? osOverride,
  final String version = '11076708',
}) {
  final os = osOverride ??
      (Platform.isMacOS
          ? 'mac'
          : Platform.isWindows
              ? 'win'
              : 'linux');
  // Google hosts: commandlinetools-<os>-<version>_latest.zip
  return 'https://dl.google.com/android/repository/'
      'commandlinetools-$os-${version}_latest.zip';
}

/// Result of an install or cleanup operation.
class AndroidSdkInstallResult {

  const AndroidSdkInstallResult({
    required this.success,
    required this.sdkRoot,
    required this.message,
    this.packages = const [],
  });
  final bool success;
  final String sdkRoot;
  final String message;
  final List<String> packages;
}

/// Installs / cleans a minimal packaging Android SDK under an oka-owned root.
class AndroidSdkInstaller {

  AndroidSdkInstaller({
    final String? sdkRoot,
    this.verbose = false,
    final Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    })? runProcess,
  })  : sdkRoot = sdkRoot ?? defaultOkaAndroidSdkRoot(),
        runProcess = runProcess ?? Process.run;
  final String sdkRoot;
  final bool verbose;
  final Future<ProcessResult> Function(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) runProcess;

  String get markerPath => p.join(sdkRoot, kOkaSdkMarkerName);

  bool get isOkaManaged => File(markerPath).existsSync();

  /// Path to sdkmanager if present under [sdkRoot].
  Future<String?> findSdkManager() async {
    final candidates = [
      p.join(sdkRoot, 'cmdline-tools', 'latest', 'bin', 'sdkmanager'),
      p.join(sdkRoot, 'cmdline-tools', 'bin', 'sdkmanager'),
      p.join(sdkRoot, 'tools', 'bin', 'sdkmanager'),
    ];
    for (final c in candidates) {
      if (await File(c).exists()) return c;
    }
    return null;
  }

  /// Bootstrap cmdline-tools + packaging packages.
  Future<AndroidSdkInstallResult> installPackagingSdk({
    final String buildTools = '35.0.0',
    final String platformApi = '34',
    final bool acceptLicenses = true,
  }) async {
    final packages = packagingSdkPackages(
      buildTools: buildTools,
      platformApi: platformApi,
    );

    try {
      await Directory(sdkRoot).create(recursive: true);
      await File(markerPath).writeAsString(
        'managed_by=oka\ncreated=${DateTime.now().toIso8601String()}\n',
      );

      // Ensure cmdline-tools present
      var sdkmanager = await findSdkManager();
      if (sdkmanager == null) {
        print('📥 Bootstrapping Android command-line tools into $sdkRoot ...');
        await _bootstrapCmdlineTools();
        sdkmanager = await findSdkManager();
      }
      if (sdkmanager == null) {
        return AndroidSdkInstallResult(
          success: false,
          sdkRoot: sdkRoot,
          message: 'sdkmanager not found after cmdline-tools bootstrap',
          packages: packages,
        );
      }

      if (acceptLicenses) {
        print('📜 Accepting Android SDK licenses...');
        await _acceptLicenses(sdkmanager);
      }

      print('📦 Installing packaging packages: ${packages.join(', ')}');
      final install = await runProcess(
        sdkmanager,
        [
          '--sdk_root=$sdkRoot',
          ...packages,
        ],
        environment: {
          ...Platform.environment,
          'ANDROID_SDK_ROOT': sdkRoot,
          'ANDROID_HOME': sdkRoot,
        },
      );

      if (verbose) {
        if (install.stdout.toString().trim().isNotEmpty) {
          print(install.stdout);
        }
        if (install.stderr.toString().trim().isNotEmpty) {
          print(install.stderr);
        }
      }

      // sdkmanager sometimes returns non-zero on license quirks; verify tools.
      final ok = await packagingToolsPresent(sdkRoot);
      if (!ok) {
        return AndroidSdkInstallResult(
          success: false,
          sdkRoot: sdkRoot,
          message:
              'sdkmanager finished (exit ${install.exitCode}) but packaging tools '
              'still missing under $sdkRoot. stderr: ${install.stderr}',
          packages: packages,
        );
      }

      return AndroidSdkInstallResult(
        success: true,
        sdkRoot: sdkRoot,
        message: 'Packaging Android SDK ready at $sdkRoot',
        packages: packages,
      );
    } catch (e) {
      return AndroidSdkInstallResult(
        success: false,
        sdkRoot: sdkRoot,
        message: 'Install failed: $e',
        packages: packages,
      );
    }
  }

  /// Remove oka-managed SDK root. Refuses if marker missing.
  Future<AndroidSdkInstallResult> cleanup({final bool force = false}) async {
    final dir = Directory(sdkRoot);
    if (!await dir.exists()) {
      return AndroidSdkInstallResult(
        success: true,
        sdkRoot: sdkRoot,
        message: 'SDK root already absent: $sdkRoot',
      );
    }
    if (!isOkaManaged && !force) {
      return AndroidSdkInstallResult(
        success: false,
        sdkRoot: sdkRoot,
        message:
            'Refusing to delete $sdkRoot (not oka-managed; missing $kOkaSdkMarkerName). '
            'Pass force only if you know this is safe.',
      );
    }
    await dir.delete(recursive: true);
    return AndroidSdkInstallResult(
      success: true,
      sdkRoot: sdkRoot,
      message: 'Removed oka-managed Android SDK at $sdkRoot',
    );
  }

  Future<void> _bootstrapCmdlineTools() async {
    final url = commandLineToolsDownloadUrl();
    final tmpZip = p.join(sdkRoot, 'commandlinetools.zip');
    final extractDir = p.join(sdkRoot, '_cmdline_extract');

    if (await Directory(extractDir).exists()) {
      await Directory(extractDir).delete(recursive: true);
    }
    await Directory(extractDir).create(recursive: true);

    final curl = await runProcess('curl', [
      '-L',
      '-f',
      '-o',
      tmpZip,
      url,
    ]);
    if (curl.exitCode != 0) {
      throw Exception(
        'Failed to download cmdline-tools from $url: ${curl.stderr}',
      );
    }

    final unzip = await runProcess('unzip', [
      '-q',
      '-o',
      tmpZip,
      '-d',
      extractDir,
    ]);
    if (unzip.exitCode != 0) {
      throw Exception('Failed to unzip cmdline-tools: ${unzip.stderr}');
    }

    // Zip contains cmdline-tools/ → move to cmdline-tools/latest
    final nested = Directory(p.join(extractDir, 'cmdline-tools'));
    final dest = Directory(p.join(sdkRoot, 'cmdline-tools', 'latest'));
    if (await dest.exists()) {
      await dest.delete(recursive: true);
    }
    await dest.parent.create(recursive: true);
    if (await nested.exists()) {
      await nested.rename(dest.path);
    } else {
      // Some zips unpack flat bin/lib
      await Directory(extractDir).rename(dest.path);
    }

    final sdkmanager = p.join(dest.path, 'bin', 'sdkmanager');
    if (!Platform.isWindows && await File(sdkmanager).exists()) {
      await runProcess('chmod', ['+x', sdkmanager]);
    }

    if (await File(tmpZip).exists()) {
      await File(tmpZip).delete();
    }
    if (await Directory(extractDir).exists()) {
      try {
        await Directory(extractDir).delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _acceptLicenses(final String sdkmanager) async {
    // Pipe "y" repeatedly into sdkmanager --licenses
    final result = await runProcess(
      'bash',
      [
        '-c',
        'yes | ${shellQuote(sdkmanager)} --sdk_root=${shellQuote(sdkRoot)} --licenses >/dev/null 2>&1 || true',
      ],
    );
    if (verbose && result.exitCode != 0) {
      print('   license helper exit ${result.exitCode} (continuing)');
    }
  }
}

String shellQuote(final String s) {
  if (!s.contains("'")) return "'$s'";
  return "'${s.replaceAll("'", r"'\''")}'";
}

/// True when aapt2, d8, zipalign, apksigner exist under [sdkRoot].
Future<bool> packagingToolsPresent(final String sdkRoot) async {
  final buildTools = Directory(p.join(sdkRoot, 'build-tools'));
  if (!await buildTools.exists()) return false;

  String? latest;
  await for (final e in buildTools.list()) {
    if (e is Directory) {
      final name = p.basename(e.path);
      if (latest == null || name.compareTo(latest) > 0) latest = name;
    }
  }
  if (latest == null) return false;

  final tools = [
    p.join(sdkRoot, 'build-tools', latest, 'aapt2'),
    p.join(sdkRoot, 'build-tools', latest, 'd8'),
    p.join(sdkRoot, 'build-tools', latest, 'zipalign'),
    p.join(sdkRoot, 'build-tools', latest, 'apksigner'),
  ];
  for (final t in tools) {
    if (!await File(t).exists()) return false;
  }

  final platforms = Directory(p.join(sdkRoot, 'platforms'));
  if (!await platforms.exists()) return false;
  var hasPlatform = false;
  await for (final e in platforms.list()) {
    if (e is Directory &&
        await File(p.join(e.path, 'android.jar')).exists()) {
      hasPlatform = true;
      break;
    }
  }
  return hasPlatform;
}
