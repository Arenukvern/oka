import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// Typed release-signing configuration (ADR-0006; closes the G2 gap).
///
/// Sources, in override order:
/// 1. explicit Dart composition ([copyWith])
/// 2. `oka.yaml` `android.signing:` section
/// 3. `android/key.properties` convention (Gradle-compatible)
/// 4. fallback: oka's debug keystore (development only)
class SigningConfig {
  /// Keystore file path (project-relative or absolute).
  final String keystorePath;

  /// Key alias inside the keystore.
  final String keyAlias;

  /// Keystore password.
  final String storePassword;

  /// Key password (defaults to [storePassword] when empty).
  final String keyPassword;

  const SigningConfig({
    this.keystorePath = '',
    this.keyAlias = '',
    this.storePassword = '',
    this.keyPassword = '',
  });

  bool get isConfigured =>
      keystorePath.isNotEmpty &&
      keyAlias.isNotEmpty &&
      storePassword.isNotEmpty;

  SigningConfig copyWith({
    String? keystorePath,
    String? keyAlias,
    String? storePassword,
    String? keyPassword,
  }) => SigningConfig(
    keystorePath: keystorePath ?? this.keystorePath,
    keyAlias: keyAlias ?? this.keyAlias,
    storePassword: storePassword ?? this.storePassword,
    keyPassword: keyPassword ?? this.keyPassword,
  );

  /// `oka.yaml`:
  /// ```yaml
  /// android:
  ///   signing:
  ///     keystore: keys/release.jks
  ///     alias: upload
  ///     store_password_env: OKA_STORE_PASS
  ///     key_password_env: OKA_KEY_PASS
  /// ```
  /// Passwords read from environment variables referenced by `*_env` keys —
  /// secrets never belong in yaml.
  factory SigningConfig.fromYamlMap(Map<dynamic, dynamic> map) {
    final storeEnv = map['store_password_env']?.toString() ?? '';
    final keyEnv = map['key_password_env']?.toString() ?? '';
    final storePass =
        map['store_password']?.toString() ??
        (storeEnv.isEmpty ? '' : Platform.environment[storeEnv] ?? '');
    final keyPass =
        map['key_password']?.toString() ??
        (keyEnv.isEmpty ? '' : Platform.environment[keyEnv] ?? '');
    return SigningConfig(
      keystorePath: map['keystore']?.toString() ?? '',
      keyAlias: map['alias']?.toString() ?? '',
      storePassword: storePass,
      keyPassword: keyPass,
    );
  }

  /// Gradle-compatible `android/key.properties`:
  /// `storeFile`, `keyAlias`, `storePassword`, `keyPassword`.
  static Future<SigningConfig?> fromKeyProperties(
    String projectPath,
  ) async {
    final file = File(p.join(projectPath, 'android', 'key.properties'));
    if (!await file.exists()) return null;
    final props = <String, String>{};
    for (final line in await file.readAsLines()) {
      final i = line.indexOf('=');
      if (i <= 0) continue;
      props[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
    final storeFile = props['storeFile'] ?? '';
    if (storeFile.isEmpty) return null;
    // Resolve storeFile relative to the android/ dir (Gradle convention).
    final ksPath = p.isAbsolute(storeFile)
        ? storeFile
        : p.join(projectPath, 'android', storeFile);
    return SigningConfig(
      keystorePath: ksPath,
      keyAlias: props['keyAlias'] ?? '',
      storePassword: props['storePassword'] ?? '',
      keyPassword: props['keyPassword'] ?? props['storePassword'] ?? '',
    );
  }

  /// Effective key password.
  String get effectiveKeyPassword =>
      keyPassword.isEmpty ? storePassword : keyPassword;

  /// Resolution chain: explicit Dart config → oka.yaml `android.signing` →
  /// `android/key.properties` → null (debug keystore fallback).
  static Future<SigningConfig?> autoResolve(BuildContext ctx) async {
    final androidYaml = ctx.config.toJson()['android'];
    if (androidYaml is Map && androidYaml['signing'] is Map) {
      final fromYaml = SigningConfig.fromYamlMap(
        androidYaml['signing'] as Map,
      );
      if (fromYaml.isConfigured) return fromYaml;
    }
    return fromKeyProperties(ctx.projectPath);
  }
}
