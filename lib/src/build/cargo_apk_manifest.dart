import 'dart:io';
import 'package:path/path.dart' as p;

import '../config/build_context.dart';

/// Generates cargo-apk manifest configuration
///
/// Translates oka.yaml Flutter and Android configuration into
/// cargo-apk's Cargo.toml [package.metadata.android] format.
class CargoApkManifest {
  final bool _verbose;

  CargoApkManifest({bool verbose = false}) : _verbose = verbose;

  /// Generate cargo-apk manifest for the Flutter Rust wrapper
  ///
  /// This creates or updates the Cargo.toml in the rust_wrapper directory
  /// with the appropriate metadata for cargo-apk based on oka.yaml config.
  Future<void> generateManifest(BuildContext ctx) async {
    // Find the oka project root (where rust_wrapper should be)
    final okaProjectRoot = _findOkaProjectRoot(ctx.projectPath);
    final cargoTomlPath = p.join(okaProjectRoot, 'rust_wrapper', 'Cargo.toml');

    if (_verbose) {
      print('📝 Generating cargo-apk manifest...');
      print('   Target: $cargoTomlPath');
    }

    // Read existing Cargo.toml
    final cargoTomlFile = File(cargoTomlPath);
    if (!await cargoTomlFile.exists()) {
      throw Exception('Rust wrapper Cargo.toml not found at $cargoTomlPath');
    }

    String cargoToml = await cargoTomlFile.readAsString();

    // Remove existing android metadata if present
    cargoToml = _removeExistingAndroidMetadata(cargoToml);

    // Add new android metadata
    final androidMetadata = _generateAndroidMetadata(ctx);
    cargoToml = _insertAndroidMetadata(cargoToml, androidMetadata);

    // Write back
    await cargoTomlFile.writeAsString(cargoToml);

    if (_verbose) {
      print('✅ Generated cargo-apk manifest');
    }
  }

  String _removeExistingAndroidMetadata(String cargoToml) {
    final lines = cargoToml.split('\n');
    final result = <String>[];
    bool inAndroidSection = false;
    int braceCount = 0;

    for (final line in lines) {
      if (line.trim() == '[package.metadata.android]') {
        inAndroidSection = true;
        continue; // Skip this line
      }

      if (inAndroidSection) {
        braceCount += '{'.allMatches(line).length;
        braceCount -= '}'.allMatches(line).length;

        if (braceCount <= 0 && line.trim().isNotEmpty) {
          // End of android section
          inAndroidSection = false;
          continue;
        }

        // Skip lines in android section
        continue;
      }

      result.add(line);
    }

    return result.join('\n');
  }

  String _insertAndroidMetadata(String cargoToml, String androidMetadata) {
    // Insert before [dependencies] section or at the end
    final depsIndex = cargoToml.indexOf('[dependencies]');
    if (depsIndex != -1) {
      return '${cargoToml.substring(0, depsIndex)}$androidMetadata\n${cargoToml.substring(depsIndex)}';
    }

    // Append at end
    return '$cargoToml\n$androidMetadata';
  }

  String _generateAndroidMetadata(BuildContext ctx) {
    final config = ctx.config;
    final android = config.android;
    final cargoApk = config.cargoApk;

    final buffer = StringBuffer();
    buffer.writeln('[package.metadata.android]');
    buffer.writeln('package_name = "${android.packageName}"');
    buffer.writeln('version_code = ${android.versionCode}');
    buffer.writeln('version_name = "${android.versionName}"');
    buffer.writeln('min_sdk_version = ${android.minSdk}');
    buffer.writeln('target_sdk_version = ${android.targetSdk}');
    buffer.writeln('compile_sdk_version = ${android.compileSdk}');

    // Application configuration from oka.yaml
    buffer.writeln();
    buffer.writeln('[package.metadata.android.application]');
    final appConfig = cargoApk.application;
    appConfig.forEach((key, value) {
      if (key == 'debuggable') {
        // Override debuggable based on build mode
        buffer.writeln('$key = ${ctx.mode.name == 'debug'}');
      } else {
        buffer.writeln('$key = "$value"');
      }
    });

    // Activity configuration from oka.yaml
    buffer.writeln();
    buffer.writeln('[package.metadata.android.application.activity]');
    final activityConfig = cargoApk.activity;
    activityConfig.forEach((key, value) {
      buffer.writeln('$key = "$value"');
    });

    // Intent filter for main activity
    buffer.writeln();
    buffer.writeln('[[package.metadata.android.application.activity.intent_filter]]');
    buffer.writeln('actions = ["android.intent.action.MAIN"]');
    buffer.writeln('categories = ["android.intent.category.LAUNCHER"]');

    // Assets configuration - cargo-apk expects assets in APK root
    buffer.writeln();
    buffer.writeln('assets = "flutter_assets"');

    // Native libraries (Flutter engine, AOT snapshot)
    if (ctx.mode.name == 'release') {
      buffer.writeln('native_libs = [');
      buffer.writeln('  "lib/libapp.so",');
      buffer.writeln(']');
    }

    // Additional assets for Flutter (ICU data, etc.)
    buffer.writeln();
    buffer.writeln('assets = "flutter_assets/icudtl.dat"');

    // Permissions from oka.yaml
    for (final permission in cargoApk.permissions) {
      buffer.writeln();
      buffer.writeln('[[package.metadata.android.uses_permission]]');
      buffer.writeln('name = "$permission"');
    }

    // Features from oka.yaml
    for (final feature in cargoApk.features) {
      buffer.writeln();
      buffer.writeln('[[package.metadata.android.uses_feature]]');
      feature.forEach((key, value) {
        buffer.writeln('$key = "$value"');
      });
    }

    // Build targets (ABIs) from oka.yaml
    if (cargoApk.buildTargets.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('build_targets = ["${cargoApk.buildTargets.join('", "')}"]');
    }

    // Signing configuration for release builds
    if (ctx.mode.name == 'release' && config.signing.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('[package.metadata.android.signing.release]');
      buffer.writeln('keystore_password = "${config.signing['store_password'] ?? ''}"');

      final keystorePath = config.signing['store_file'];
      if (keystorePath != null) {
        buffer.writeln('path = "$keystorePath"');
      }
    }

    return buffer.toString();
  }

  /// Update manifest with dynamic paths after Flutter compilation
  ///
  /// This is called after Flutter assets and AOT are built to update
  /// the manifest with the actual file paths.
  Future<void> updateManifestWithBuiltAssets(BuildContext ctx, String flutterAssetsDir, String aotDir) async {
    // For cargo-apk, we need to ensure the assets are in the right location
    // cargo-apk copies assets from the specified directory to the APK root

    // Find the oka project root (where rust_wrapper should be)
    final okaProjectRoot = _findOkaProjectRoot(ctx.projectPath);
    final rustWrapperDir = p.join(okaProjectRoot, 'rust_wrapper');

    // Copy flutter_assets to rust_wrapper directory so cargo-apk can find them
    final rustAssetsDir = p.join(rustWrapperDir, 'flutter_assets');
    final sourceAssetsDir = Directory(flutterAssetsDir);

    if (await sourceAssetsDir.exists()) {
      // Remove old assets
      if (await Directory(rustAssetsDir).exists()) {
        await Directory(rustAssetsDir).delete(recursive: true);
      }

      // Copy new assets
      await _copyDirectory(sourceAssetsDir, Directory(rustAssetsDir));

      if (_verbose) {
        print('📁 Copied flutter_assets to rust_wrapper directory');
      }
    }

    // Copy AOT snapshot for release builds
    if (ctx.mode.name == 'release' && aotDir.isNotEmpty) {
      final aotSource = p.join(aotDir, 'app.so');
      final aotDest = p.join(rustWrapperDir, 'lib', 'libapp.so');

      if (await File(aotSource).exists()) {
        await Directory(p.dirname(aotDest)).create(recursive: true);
        await File(aotSource).copy(aotDest);

        if (_verbose) {
          print('📁 Copied AOT snapshot to rust_wrapper/lib/');
        }
      }
    }

    if (_verbose) {
      print('🔄 Prepared assets for cargo-apk build');
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);

    await for (final entity in source.list(recursive: true)) {
      final relativePath = p.relative(entity.path, from: source.path);
      final destPath = p.join(destination.path, relativePath);

      if (entity is File) {
        await entity.copy(destPath);
      } else if (entity is Directory) {
        await Directory(destPath).create(recursive: true);
      }
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
}
