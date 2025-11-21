import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;

import '../config/flutter_config.dart';
import '../config/build_context.dart';

/// Flutter asset bundler that prepares flutter_assets/ directory
///
/// Uses Flutter tools to create the asset bundle that will be packaged
/// into the APK by cargo-apk.
class FlutterAssetBundler {
  final bool _verbose;

  FlutterAssetBundler({bool verbose = false}) : _verbose = verbose;

  /// Bundle Flutter assets for the given build context
  ///
  /// This runs `flutter build bundle` to create the flutter_assets/
  /// directory that contains all compiled assets, fonts, and metadata
  /// needed by the Flutter engine at runtime.
  Future<String> bundleAssets(BuildContext ctx) async {
    final flutterAssetsDir = p.join(ctx.buildDir, 'flutter_assets');

    if (_verbose) {
      print('🎨 Bundling Flutter assets...');
      print('   Entrypoint: ${ctx.config.flutter.entrypoint}');
      print('   Build mode: ${ctx.config.flutter.buildMode}');
      print('   Output: $flutterAssetsDir');
    }

    // Clean previous assets
    final assetsDir = Directory(flutterAssetsDir);
    if (await assetsDir.exists()) {
      await assetsDir.delete(recursive: true);
    }

    // Build asset bundle using Flutter tools
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
      'bundle',
      '--target', ctx.config.flutter.entrypoint,
      '--target-platform', flutterTargetPlatform,
      '--${ctx.config.flutter.buildMode}',
      '--asset-dir', flutterAssetsDir,
    ];

    // Note: --tree-shake-icons is not applicable to bundle command
    // Tree shaking icons only applies to AOT compilation

    // Add any custom build arguments
    buildArgs.addAll(ctx.config.flutter.buildArgs);

    if (_verbose) {
      print('   Running: flutter ${buildArgs.join(' ')}');
    }

    final result = await Process.run(
      'flutter',
      buildArgs,
      workingDirectory: ctx.projectPath,
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
      throw Exception('Flutter asset bundling failed: ${result.stderr}');
    }

    // Verify assets were created
    if (!await assetsDir.exists()) {
      throw Exception('Flutter assets directory was not created');
    }

    final assets = await assetsDir.list().length;
    if (_verbose) {
      print('✅ Created $assets asset files');
    }

    return flutterAssetsDir;
  }

  /// Bundle Flutter AOT snapshot for release builds
  ///
  /// For release builds, we need to compile Dart code to native code
  /// that can be loaded by the Flutter engine.
  Future<String> bundleAotSnapshot(BuildContext ctx) async {
    if (ctx.config.flutter.buildMode != 'release') {
      if (_verbose) {
        print('⏭️  Skipping AOT compilation (not release mode)');
      }
      return '';
    }

    final aotDir = p.join(ctx.buildDir, 'aot');

    if (_verbose) {
      print('⚡ Compiling AOT snapshot...');
      print('   Output: $aotDir');
    }

    // Clean previous AOT
    final aotDirectory = Directory(aotDir);
    if (await aotDirectory.exists()) {
      await aotDirectory.delete(recursive: true);
    }

    // Build AOT snapshot
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
      'aot',
      '--target', ctx.config.flutter.entrypoint,
      '--target-platform', flutterTargetPlatform,
      '--output-dir', aotDir,
    ];

    // Add tree shaking for smaller binaries
    if (ctx.config.flutter.treeShakeIcons) {
      buildArgs.add('--tree-shake-icons');
    }

    // Add any custom build arguments
    buildArgs.addAll(ctx.config.flutter.buildArgs);

    if (_verbose) {
      print('   Running: flutter ${buildArgs.join(' ')}');
    }

    final result = await Process.run(
      'flutter',
      buildArgs,
      workingDirectory: ctx.projectPath,
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
      throw Exception('Flutter AOT compilation failed: ${result.stderr}');
    }

    // Verify AOT files were created
    final appSo = File(p.join(aotDir, 'app.so'));
    if (!await appSo.exists()) {
      throw Exception('Flutter AOT app.so was not created');
    }

    if (_verbose) {
      final size = await appSo.length();
      print('✅ Created AOT snapshot (${(size / 1024 / 1024).toStringAsFixed(2)} MB)');
    }

    return aotDir;
  }

  /// Prepare Flutter engine artifacts
  ///
  /// Copies necessary Flutter engine files (ICU data, etc.) to the build directory
  Future<void> prepareEngineArtifacts(BuildContext ctx) async {
    if (_verbose) {
      print('🔧 Preparing Flutter engine artifacts...');
    }

    // Find Flutter SDK
    final flutterSdk = await _findFlutterSdk();
    final engineArtifacts = p.join(flutterSdk, 'bin', 'cache', 'artifacts', 'engine');

    // Copy ICU data
    final icuSrc = p.join(engineArtifacts, 'android-arm64', 'icudtl.dat');
    final icuDst = p.join(ctx.buildDir, 'flutter_assets', 'icudtl.dat');

    final icuFile = File(icuSrc);
    if (await icuFile.exists()) {
      await icuFile.copy(icuDst);
      if (_verbose) {
        print('   ✅ Copied ICU data');
      }
    } else {
      if (_verbose) {
        print('   ⚠️  ICU data not found at $icuSrc');
      }
    }
  }

  Future<String> _findFlutterSdk() async {
    // Try flutter command
    try {
      final result = await Process.run('flutter', ['--version', '--machine']);
      if (result.exitCode == 0) {
        final output = result.stdout as String;
        final json = jsonDecode(output);
        return json['flutterRoot'] as String;
      }
    } catch (_) {}

    // Try which flutter
    try {
      final result = await Process.run('which', ['flutter']);
      if (result.exitCode == 0) {
        final flutterPath = (result.stdout as String).trim();
        final sdkPath = p.dirname(p.dirname(flutterPath));
        return sdkPath;
      }
    } catch (_) {}

    // Try common locations
    final home = Platform.environment['HOME'] ?? '';
    final commonPaths = [
      p.join(home, 'flutter'),
      p.join(home, 'development', 'flutter'),
      p.join(home, 'snap', 'flutter', 'common', 'flutter'),
      '/opt/flutter',
    ];

    for (final path in commonPaths) {
      if (await Directory(path).exists()) {
        return path;
      }
    }

    throw Exception('Flutter SDK not found. Please ensure Flutter is installed and in PATH.');
  }
}
