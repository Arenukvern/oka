import 'dart:io';
import 'package:path/path.dart' as p;

import '../config/build_context.dart';
import '../config/flutter_config.dart';

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
      return cargoToml.substring(0, depsIndex) +
             androidMetadata +
             '\n' +
             cargoToml.substring(depsIndex);
    }

    // Append at end
    return cargoToml + '\n' + androidMetadata;
  }

  String _generateAndroidMetadata(BuildContext ctx) {
    final config = ctx.config;
    final android = config.android;
    final flutter = config.flutter;

    final buffer = StringBuffer();
    buffer.writeln('[package.metadata.android]');
    buffer.writeln('package_name = "${android.packageName}"');
    buffer.writeln('version_code = ${android.versionCode}');
    buffer.writeln('version_name = "${android.versionName}"');
    buffer.writeln('min_sdk_version = ${android.minSdk}');
    buffer.writeln('target_sdk_version = ${android.targetSdk}');
    buffer.writeln('compile_sdk_version = ${android.compileSdk}');

    // Application configuration
    buffer.writeln();
    buffer.writeln('[package.metadata.android.application]');
    buffer.writeln('label = "${config.name}"');
    buffer.writeln('icon = "@mipmap/ic_launcher"');
    buffer.writeln('debuggable = ${ctx.mode.name == 'debug'}');
    buffer.writeln('extract_native_libs = true');

    // Activity configuration
    buffer.writeln();
    buffer.writeln('[package.metadata.android.application.activity]');
    buffer.writeln('label = "${config.name}"');
    buffer.writeln('launch_mode = "singleTop"');
    buffer.writeln('orientation = "portrait"');
    buffer.writeln('exported = true');
    buffer.writeln('config_changes = "orientation|keyboardHidden|screenSize"');

    // Intent filter for main activity
    buffer.writeln();
    buffer.writeln('[[package.metadata.android.application.activity.intent_filter]]');
    buffer.writeln('actions = ["android.intent.action.MAIN"]');
    buffer.writeln('categories = ["android.intent.category.LAUNCHER"]');

    // Assets configuration
    final flutterAssetsPath = p.join(ctx.buildDir, 'flutter_assets');
    buffer.writeln();
    buffer.writeln('assets = "$flutterAssetsPath"');

    // Native libraries (Flutter engine, AOT snapshot)
    if (flutter.buildMode == 'release') {
      final aotDir = p.join(ctx.buildDir, 'aot');
      buffer.writeln('native_libs = [');
      buffer.writeln('  "$aotDir/libapp.so",');
      buffer.writeln('  # Add Flutter engine libraries here');
      buffer.writeln(']');
    }

    // Uses permissions (basic set for Flutter apps)
    buffer.writeln();
    buffer.writeln('[[package.metadata.android.uses_permission]]');
    buffer.writeln('name = "android.permission.INTERNET"');

    buffer.writeln();
    buffer.writeln('[[package.metadata.android.uses_permission]]');
    buffer.writeln('name = "android.permission.ACCESS_NETWORK_STATE"');

    // Build targets (ABIs)
    if (android.abis.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('build_targets = ["${android.abis.join('", "')}"]');
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
    // Find the oka project root (where rust_wrapper should be)
    final okaProjectRoot = _findOkaProjectRoot(ctx.projectPath);
    final cargoTomlPath = p.join(okaProjectRoot, 'rust_wrapper', 'Cargo.toml');
    String cargoToml = await File(cargoTomlPath).readAsString();

    // Update assets path
    cargoToml = cargoToml.replaceAll(
      RegExp(r'assets = "[^"]*"'),
      'assets = "$flutterAssetsDir"'
    );

    // Update native libs for release builds
    if (ctx.config.flutter.buildMode == 'release') {
      final appSoPath = p.join(aotDir, 'app.so');
      final nativeLibsEntry = 'native_libs = [\n  "$appSoPath",\n]';
      cargoToml = cargoToml.replaceAll(
        RegExp(r'native_libs = \[[\s\S]*?\]'),
        nativeLibsEntry
      );
    }

    await File(cargoTomlPath).writeAsString(cargoToml);

    if (_verbose) {
      print('🔄 Updated cargo-apk manifest with built asset paths');
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
