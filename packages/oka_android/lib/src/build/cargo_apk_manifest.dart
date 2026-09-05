import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:oka_core/src/config/build_context.dart';

/// Generates cargo-apk `[package.metadata.android]` TOML **as text**.
///
/// Important: the default `oka build apk` path does **not** use this class.
/// Hybrid/experimental builds may write the result only to an **explicit**
/// output path (typically under the app's `.oka_cache/`), never by mutating a
/// shared tool-owned `rust_wrapper/Cargo.toml` in place without a destination.
class CargoApkManifest {
  final bool verbose;

  CargoApkManifest({this.verbose = false});

  /// Pure TOML fragment for `[package.metadata.android*]` tables.
  String generateAndroidMetadataToml(BuildContext ctx) {
    final android = ctx.config.android;
    final cargoApk = ctx.config.cargoApk;

    final buffer = StringBuffer();
    buffer.writeln('[package.metadata.android]');
    buffer.writeln('package = "${android.packageName}"');
    buffer.writeln('apk_name = "${ctx.config.name.isEmpty ? 'app' : ctx.config.name}"');
    if (android.versionCode != 0) {
      buffer.writeln('version_code = ${android.versionCode}');
    }
    if (android.versionName.isNotEmpty) {
      buffer.writeln('version_name = "${android.versionName}"');
    }
    final minSdk = android.minSdk.isEmpty ? '21' : android.minSdk;
    final targetSdk = android.targetSdk.isEmpty ? '34' : android.targetSdk;
    buffer.writeln('min_sdk_version = $minSdk');
    buffer.writeln('target_sdk_version = $targetSdk');

    final targets = cargoApk.buildTargets.isNotEmpty
        ? cargoApk.buildTargets
        : (android.abis.isNotEmpty ? android.abis : ['arm64-v8a']);
    buffer.writeln(
      'build_targets = [${targets.map((t) => '"$t"').join(', ')}]',
    );

    buffer.writeln();
    buffer.writeln('[package.metadata.android.application]');
    final label = cargoApk.application['label'] ?? ctx.config.name;
    buffer.writeln('label = "$label"');
    buffer.writeln('debuggable = ${ctx.mode.isDebug}');

    // Single assets directory (must not duplicate the key).
    buffer.writeln();
    buffer.writeln('[[package.metadata.android.application.activity]]');
    buffer.writeln('name = ".MainActivity"');
    buffer.writeln('exported = true');
    buffer.writeln('launch_mode = "singleTop"');

    buffer.writeln();
    buffer.writeln(
      '[[package.metadata.android.application.activity.intent_filter]]',
    );
    buffer.writeln('actions = ["android.intent.action.MAIN"]');
    buffer.writeln('categories = ["android.intent.category.LAUNCHER"]');

    for (final permission in cargoApk.permissions) {
      buffer.writeln();
      buffer.writeln('[[package.metadata.android.uses_permission]]');
      buffer.writeln('name = "$permission"');
    }

    return buffer.toString();
  }

  /// Writes metadata **only** to [destinationCargoToml] (must be provided).
  ///
  /// Does not walk the filesystem looking for oka's shared rust_wrapper.
  Future<void> writeManifestTo({
    required BuildContext ctx,
    required String destinationCargoToml,
  }) async {
    final dest = File(destinationCargoToml);
    await dest.parent.create(recursive: true);

    String base;
    if (await dest.exists()) {
      base = await dest.readAsString();
      base = stripAndroidMetadataSections(base);
    } else {
      base = '''
[package]
name = "flutter_wrapper"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
''';
    }

    final metadata = generateAndroidMetadataToml(ctx);
    final merged = insertAndroidMetadata(base, metadata);
    await dest.writeAsString(merged);

    if (verbose) {
      print('📝 Wrote cargo-apk metadata to $destinationCargoToml');
    }
  }

  /// @deprecated Prefer [writeManifestTo] with an explicit path.
  /// Kept for API compatibility; refuses to mutate a path named rust_wrapper
  /// under a discovered oka root unless [allowSharedWrapper] is true.
  Future<void> generateManifest(
    BuildContext ctx, {
    bool allowSharedWrapper = false,
  }) async {
    final dest = p.join(ctx.buildDir, 'cargo_apk', 'Cargo.toml');
    if (!allowSharedWrapper) {
      await writeManifestTo(ctx: ctx, destinationCargoToml: dest);
      return;
    }
    // Explicit opt-in: still write under buildDir to avoid corruption.
    await writeManifestTo(ctx: ctx, destinationCargoToml: dest);
  }

  /// Removes prior `[package.metadata.android...]` tables from TOML text.
  static String stripAndroidMetadataSections(String cargoToml) {
    final lines = cargoToml.split('\n');
    final result = <String>[];
    var skipping = false;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[package.metadata.android')) {
        skipping = true;
        continue;
      }
      if (skipping) {
        // Next top-level table that is not android metadata ends skip.
        if (trimmed.startsWith('[') &&
            !trimmed.startsWith('[package.metadata.android')) {
          skipping = false;
          result.add(line);
        }
        continue;
      }
      result.add(line);
    }
    return result.join('\n');
  }

  static String insertAndroidMetadata(String cargoToml, String androidMetadata) {
    final depsIndex = cargoToml.indexOf('[dependencies]');
    if (depsIndex != -1) {
      return '${cargoToml.substring(0, depsIndex)}$androidMetadata\n${cargoToml.substring(depsIndex)}';
    }
    return '$cargoToml\n$androidMetadata';
  }

  /// Validates generated metadata has no duplicate `assets =` keys and parses
  /// as non-empty android section.
  static bool isWellFormedMetadata(String tomlFragment) {
    final assetsMatches = RegExp(r'^\s*assets\s*=', multiLine: true)
        .allMatches(tomlFragment)
        .length;
    if (assetsMatches > 1) return false;
    if (!tomlFragment.contains('[package.metadata.android]')) return false;
    // Free-floating version_code before any table is invalid.
    final firstTable = tomlFragment.indexOf('[');
    if (firstTable > 0) {
      final preamble = tomlFragment.substring(0, firstTable);
      if (RegExp(r'version_code\s*=').hasMatch(preamble)) return false;
    }
    return true;
  }
}
