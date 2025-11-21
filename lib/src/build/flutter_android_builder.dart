import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/build_context.dart';
import 'cargo_apk_manifest.dart';
import 'flutter_asset_bundler.dart';
import 'sdk_locator.dart';

/// Flutter Android builder using hybrid approach
///
/// Combines Flutter tools for Dart compilation and asset bundling
/// with cargo-apk for Android APK packaging and Rust NativeActivity hosting.
class FlutterAndroidBuilder {
  final SdkLocator _sdkLocator;
  final FlutterAssetBundler _assetBundler;
  final CargoApkManifest _manifestGenerator;
  final bool _verbose;

  FlutterAndroidBuilder(this._sdkLocator, {bool verbose = false})
    : _assetBundler = FlutterAssetBundler(verbose: verbose),
      _manifestGenerator = CargoApkManifest(verbose: verbose),
      _verbose = verbose;

  /// Build Flutter APK using hybrid pipeline
  ///
  /// Pipeline:
  /// 1. Generate cargo-apk manifest from oka.yaml
  /// 2. Bundle Flutter assets using flutter build bundle
  /// 3. AOT compile Dart for release builds
  /// 4. Update manifest with built asset paths
  /// 5. Build APK using cargo-apk
  Future<BuildArtifact> buildFlutterApk(BuildContext ctx) async {
    final startTime = DateTime.now();

    try {
      print('🚀 Building Flutter ${ctx.mode.name} APK (Hybrid)...');

      // Validate tools
      await _validateTools(ctx);

      // Create build directories
      await _createBuildDirectories(ctx);

      // Generate initial cargo-apk manifest
      print('📝 Generating cargo-apk manifest...');
      await _manifestGenerator.generateManifest(ctx);

      // Bundle Flutter assets
      print('🎨 Bundling Flutter assets...');
      final flutterAssetsDir = await _assetBundler.bundleAssets(ctx);

      // AOT compile for release builds
      String aotDir = '';
      if (ctx.config.flutter.buildMode == 'release') {
        print('⚡ AOT compiling Dart code...');
        aotDir = await _assetBundler.bundleAotSnapshot(ctx);
      }

      // Prepare Flutter engine artifacts
      await _assetBundler.prepareEngineArtifacts(ctx);

      // Update manifest with built asset paths and copy assets to rust_wrapper
      await _manifestGenerator.updateManifestWithBuiltAssets(
        ctx,
        flutterAssetsDir,
        aotDir,
      );

      // Build APK using cargo-apk
      print('📦 Building ${ctx.buildAab ? 'AAB' : 'APK'} with cargo-apk...');
      final apkPath = await _buildWithCargoApk(ctx);

      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);

      final outputFile = File(apkPath);
      final size = await outputFile.length();
      final outputType = ctx.buildAab ? 'AAB' : 'APK';

      print('✅ Flutter $outputType build successful in ${duration.inSeconds}s');
      print('📍 $outputType: $apkPath');
      print('📊 Size: ${(size / 1024 / 1024).toStringAsFixed(2)} MB');

      return BuildArtifact.fromJson({
        'apk_path': apkPath,
        'size': size,
        'build_duration': duration.inMilliseconds,
        'timestamp': endTime.millisecondsSinceEpoch,
        'success': true,
      });
    } catch (e, stackTrace) {
      final endTime = DateTime.now();
      final duration = endTime.difference(startTime);

      print('❌ Flutter APK build failed: $e');
      if (_verbose) {
        print(stackTrace);
      }

      return BuildArtifact.fromJson({
        'apk_path': '',
        'size': 0,
        'build_duration': duration.inMilliseconds,
        'timestamp': endTime.millisecondsSinceEpoch,
        'success': false,
        'error': e.toString(),
      });
    }
  }

  /// Install and run APK on device
  Future<void> installAndRun(BuildContext ctx, String apkPath) async {
    print('📱 Installing and running APK...');

    // Find ADB
    final adb = await _sdkLocator.findAdb();

    // Install APK
    final installResult = await Process.run(adb, ['install', '-r', apkPath]);
    if (installResult.exitCode != 0) {
      throw Exception('APK installation failed: ${installResult.stderr}');
    }

    print('✅ APK installed successfully');

    // Launch app
    final packageName = ctx.config.android.packageName;
    final launchResult = await Process.run(adb, [
      'shell',
      'am',
      'start',
      '-n',
      '$packageName/.MainActivity',
    ]);

    if (launchResult.exitCode != 0) {
      print('⚠️  Could not auto-launch app: ${launchResult.stderr}');
      print('   You can manually launch: $packageName');
    } else {
      print('🚀 App launched successfully');
    }
  }

  Future<String> _buildWithCargoApk(BuildContext ctx) async {
    // Find the oka project root (where rust_wrapper should be)
    final okaProjectRoot = _findOkaProjectRoot(ctx.projectPath);
    final rustWrapperDir = p.join(okaProjectRoot, 'rust_wrapper');

    // Check if we can get Android environment (SDK available)
    final testEnvironment = await _getAndroidEnvironment();
    final hasAndroidSdk =
        testEnvironment.containsKey('ANDROID_SDK_ROOT') ||
        testEnvironment.containsKey('ANDROID_HOME');

    if (!hasAndroidSdk) {
      // Android SDK not available, fall back to Flutter APK build
      print('📦 Android SDK not found, falling back to Flutter APK build...');
      return await _buildWithFlutter(ctx);
    }

    final apkOutputDir = p.join(ctx.buildDir, 'rust_build');

    // Ensure output directory exists
    await Directory(apkOutputDir).create(recursive: true);

    // Build arguments for cargo apk/aab
    final buildArgs = <String>[if (ctx.buildAab) 'aab' else 'apk', 'build'];

    // Add build mode
    switch (ctx.mode.name) {
      case 'release':
        buildArgs.add('--release');
        break;
      case 'profile':
        // cargo-apk doesn't have profile, use release
        buildArgs.add('--release');
        break;
      case 'debug':
      default:
        // Use debug by default
        break;
    }

    // Add target ABI if specified
    if (ctx.targetAbi.isNotEmpty) {
      buildArgs.add('--target');
      buildArgs.add(ctx.targetAbi);
    }

    // Add verbose flag
    if (_verbose) {
      buildArgs.add('--verbose');
    }

    if (_verbose) {
      print('   Running: cargo ${buildArgs.join(' ')}');
      print('   Working directory: $rustWrapperDir');
    }

    // Set up environment variables for cargo-apk
    final environment = await _getAndroidEnvironment();

    final result = await Process.run(
      'cargo',
      buildArgs,
      workingDirectory: rustWrapperDir,
      environment: environment,
    );

    if (_verbose) {
      if (result.stdout.toString().isNotEmpty) {
        print('cargo-apk stdout: ${result.stdout}');
      }
      if (result.stderr.toString().isNotEmpty) {
        print('cargo-apk stderr: ${result.stderr}');
      }
    }

    if (result.exitCode != 0) {
      throw Exception('cargo-apk build failed: ${result.stderr}');
    }

    // Find the generated APK/AAB
    final fileExtension = ctx.buildAab ? 'aab' : 'apk';
    final filePattern = ctx.mode.name == 'release'
        ? RegExp(r'flutter_wrapper.*\.$fileExtension')
        : RegExp(r'flutter_wrapper.*-debug\.$fileExtension');

    final outputFiles = await Directory(rustWrapperDir)
        .list()
        .where(
          (entity) =>
              entity is File && filePattern.hasMatch(p.basename(entity.path)),
        )
        .toList();

    if (outputFiles.isEmpty) {
      throw Exception(
        '${fileExtension.toUpperCase()} file not found after cargo-apk build',
      );
    }

    final outputPath = outputFiles.first.path;

    // Move file to build directory
    final finalOutputPath = p.join(
      ctx.buildDir,
      'app-${ctx.mode.name}.$fileExtension',
    );
    await File(outputPath).copy(finalOutputPath);

    return finalOutputPath;
  }

  /// Fallback APK build using Flutter tools directly
  Future<String> _buildWithFlutter(BuildContext ctx) async {
    print('🔧 Building APK using Flutter tools...');

    // Map our target platform to Flutter's expected format
    String flutterTargetPlatform;
    switch (ctx.config.flutter.targetPlatform.toLowerCase()) {
      case 'android':
        flutterTargetPlatform = 'android-arm'; // Default to ARM for Android
        break;
      default:
        flutterTargetPlatform = ctx.config.flutter.targetPlatform;
    }

    final buildArgs = <String>[
      'build',
      'apk',
      '--target',
      ctx.config.flutter.entrypoint,
      '--target-platform',
      flutterTargetPlatform,
    ];

    // Add build mode
    switch (ctx.mode.name) {
      case 'release':
        buildArgs.add('--release');
        break;
      case 'profile':
        buildArgs.add('--profile');
        break;
      case 'debug':
      default:
        buildArgs.add('--debug');
        break;
    }

    // Add tree shaking for release
    if (ctx.config.flutter.treeShakeIcons && ctx.mode.name == 'release') {
      buildArgs.add('--tree-shake-icons');
    }

    // Add custom build args
    buildArgs.addAll(ctx.config.flutter.buildArgs);

    if (_verbose) {
      print('   Running: flutter ${buildArgs.join(' ')}');
    }

    final environment = await _getAndroidEnvironment();
    final result = await Process.run(
      'flutter',
      buildArgs,
      workingDirectory: ctx.projectPath,
      environment: environment,
    );

    if (_verbose) {
      if (result.stdout.toString().isNotEmpty) {
        print('Flutter stdout: ${result.stdout}');
      }
      if (result.stderr.toString().isNotEmpty) {
        print('Flutter stderr: ${result.stderr}');
      }
    }

    if (result.exitCode != 0) {
      throw Exception('Flutter APK build failed: ${result.stderr}');
    }

    // Find the generated APK in build/app/outputs/flutter-apk/
    final apkPath = p.join(
      ctx.projectPath,
      'build',
      'app',
      'outputs',
      'flutter-apk',
      'app-${ctx.mode.name}.apk',
    );

    if (!await File(apkPath).exists()) {
      throw Exception('Flutter APK not found at expected location: $apkPath');
    }

    // Copy to our build directory
    final finalApkPath = p.join(ctx.buildDir, 'app-${ctx.mode.name}.apk');
    await File(apkPath).copy(finalApkPath);

    return finalApkPath;
  }

  Future<void> _createBuildDirectories(BuildContext ctx) async {
    final dirs = [
      ctx.buildDir,
      p.join(ctx.buildDir, 'flutter_assets'),
      p.join(ctx.buildDir, 'aot'),
      p.join(ctx.buildDir, 'rust_build'),
    ];

    for (final dir in dirs) {
      await Directory(dir).create(recursive: true);
    }
  }

  /// Find the oka project root directory containing rust_wrapper
  String _findOkaProjectRoot(String startPath) {
    var current = startPath;

    // Try up to 5 levels up to find rust_wrapper directory
    for (var i = 0; i < 5; i++) {
      final rustWrapperPath = p.join(current, 'rust_wrapper', 'Cargo.toml');
      if (File(rustWrapperPath).existsSync()) {
        return current;
      }

      final parent = p.dirname(current);
      if (parent == current) {
        // Reached filesystem root
        break;
      }
      current = parent;
    }

    // Fallback: assume startPath is the project root
    return startPath;
  }

  /// Get environment variables needed for Android builds
  ///
  /// Leverages Flutter's Android SDK detection since Flutter already knows
  /// where the Android SDK is installed (especially when installed via Android Studio).
  Future<Map<String, String>> _getAndroidEnvironment() async {
    final environment = Map<String, String>.from(Platform.environment);

    // Check if Android SDK environment variables are already set
    final hasAndroidSdk =
        environment.containsKey('ANDROID_SDK_ROOT') ||
        environment.containsKey('ANDROID_HOME');

    if (!hasAndroidSdk) {
      try {
        // First, try to get Android SDK path from Flutter's known locations
        final androidSdkPath = await _getAndroidSdkFromFlutter();
        if (androidSdkPath != null) {
          environment['ANDROID_SDK_ROOT'] = androidSdkPath;
          environment['ANDROID_HOME'] =
              androidSdkPath; // Some tools use ANDROID_HOME
          if (_verbose) {
            print('   Flutter-detected Android SDK: $androidSdkPath');
          }
        } else {
          // Fallback to manual detection
          final manualSdkPath = await _sdkLocator.findAndroidSdk();
          environment['ANDROID_SDK_ROOT'] = manualSdkPath;
          environment['ANDROID_HOME'] = manualSdkPath;
          if (_verbose) {
            print('   Manually detected Android SDK: $manualSdkPath');
          }
        }
      } catch (e) {
        if (_verbose) {
          print('   Warning: Could not locate Android SDK: $e');
          print(
            '   Flutter works because it has sophisticated Android SDK detection built-in.',
          );
          print('   Common Android Studio SDK locations:');
          print('     macOS: ~/Library/Android/sdk');
          print('     Linux: ~/Android/Sdk');
          print('     Windows: %LOCALAPPDATA%\\Android\\Sdk');
          print(
            '   Set ANDROID_SDK_ROOT environment variable or install Android SDK via Android Studio.',
          );
        }
      }
    } else {
      if (_verbose) {
        print('   Android SDK environment variables already set');
      }
    }

    return environment;
  }

  /// Get Android SDK path using Flutter's detection logic
  ///
  /// Flutter finds Android SDK in these locations (in order):
  /// 1. ANDROID_SDK_ROOT / ANDROID_HOME environment variables
  /// 2. Android Studio installation paths
  /// 3. Common system paths
  ///
  /// This mirrors how Flutter's doctor command detects Android SDK.
  Future<String?> _getAndroidSdkFromFlutter() async {
    // Check common Android Studio installation paths that Flutter knows about
    final home = Platform.environment['HOME'] ?? '';
    final possiblePaths = [
      // macOS Android Studio default locations
      '$home/Library/Android/sdk',
      '/Applications/Android Studio.app/sdk', // Android Studio app bundle
      '/Users/Shared/Android/sdk', // Shared system location
      // Linux Android Studio default locations
      '$home/Android/Sdk',
      '$home/android-sdk', // Alternative Linux location
      // Windows Android Studio default locations
      '$home/AppData/Local/Android/Sdk',
      '$home/AppData/Local/Android/sdk',

      // System-wide installations
      '/opt/android-sdk',
      '/usr/local/android-sdk',
      '/Library/Android/sdk', // macOS system-wide
      'C:\\Android\\android-sdk', // Windows system
    ];

    for (final path in possiblePaths) {
      if (await Directory(path).exists()) {
        // Verify it has the basic Android SDK structure
        final buildToolsDir = Directory('$path/build-tools');
        final platformsDir = Directory('$path/platforms');
        final platformToolsDir = Directory('$path/platform-tools');

        // Check if essential SDK directories exist (Flutter requires these)
        if (await platformsDir.exists() &&
            (await buildToolsDir.exists() || await platformToolsDir.exists())) {
          return path;
        }
      }
    }

    // Try to infer from existing environment or flutter config
    try {
      // Check if we can run a flutter command to get SDK info
      // This is a last resort since we can't run flutter in sandbox
      final localAppData = Platform.environment['LOCALAPPDATA'];
      final programFiles = Platform.environment['PROGRAMFILES'];
      final programFilesX86 = Platform.environment['PROGRAMFILES(X86)'];

      // Additional Windows paths
      if (localAppData != null) {
        final winPath = '$localAppData\\Android\\Sdk';
        if (await Directory(winPath).exists()) {
          return winPath;
        }
      }
    } catch (_) {
      // Ignore errors in additional path checking
    }

    return null;
  }

  Future<void> _validateTools(BuildContext ctx) async {
    print('Validating tools...');

    // Check Flutter
    try {
      final flutterResult = await Process.run('flutter', ['--version']);
      if (flutterResult.exitCode != 0) {
        throw Exception('Flutter not found or not working');
      }
      if (_verbose) {
        print('✅ Flutter: OK');
      }
    } catch (e) {
      throw Exception('Flutter validation failed: $e');
    }

    // Check cargo-apk
    try {
      final cargoApkResult = await Process.run('cargo', ['apk', 'version']);
      if (cargoApkResult.exitCode != 0) {
        throw Exception(
          'cargo-apk not found or not working. Install with: cargo install cargo-apk',
        );
      }
      if (_verbose) {
        print('✅ cargo-apk: OK (${cargoApkResult.stdout.trim()})');
      }
    } catch (e) {
      throw Exception(
        'cargo-apk validation failed: $e. Install with: cargo install cargo-apk',
      );
    }

    // Check Android SDK (needed for cargo-apk APK packaging)
    print('Checking Android SDK tools...');
    try {
      await _sdkLocator.validateTools();
    } catch (e) {
      print(
        '⚠️  Android SDK not found. Flutter builds will work but cargo-apk packaging requires Android SDK.',
      );
      print('   Install Android SDK or use traditional Gradle builds for now.');
      print('   Error: $e');
      // Don't fail here - let cargo-apk fail with a better error message
    }
  }
}
