import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../build/aab_layout.dart';
import '../build/toolchain.dart';
import '../compilation/process_runner.dart';
import '../signing_config.dart';

Future<void> signApk({
  required BuildContext ctx,
  required String apksigner,
  required String alignedApk,
  required String signedApk,
  SigningConfig? signing,
  AndroidProcessRunner processRunner = runAndroidProcess,
}) async {
  final configured =
      signing ?? await SigningConfig.autoResolve(ctx) ?? const SigningConfig();
  final List<String> arguments;
  if (configured.isConfigured) {
    print('🔐 Signing with configured keystore: ${configured.keyAlias}');
    arguments = [
      'sign',
      '--ks',
      configured.keystorePath,
      '--ks-pass',
      'pass:${configured.storePassword}',
      '--ks-key-alias',
      configured.keyAlias,
      '--key-pass',
      'pass:${configured.effectiveKeyPassword}',
      '--out',
      signedApk,
      alignedApk,
    ];
  } else {
    if (ctx.mode.isRelease) {
      print(
        '⚠️  No signing configuration found (android/key.properties or '
        'oka.yaml android.signing) — falling back to the DEBUG keystore.\n'
        '   Store uploads will be rejected; configure signing for releases.',
      );
    }
    arguments = [
      'sign',
      '--ks',
      await debugKeystore(processRunner: processRunner),
      '--ks-pass',
      'pass:android',
      '--out',
      signedApk,
      alignedApk,
    ];
  }
  final result = await processRunner(apksigner, arguments);
  if (result.exitCode != 0) {
    throw Exception('apksigner failed: ${result.stderr}');
  }
}

Future<void> signBundle({
  required BuildContext ctx,
  required ResolvedToolchain toolchain,
  required String unsignedBundle,
  required String signedBundle,
  SigningConfig? signing,
  AndroidProcessRunner processRunner = runAndroidProcess,
}) async {
  final configured =
      signing ?? await SigningConfig.autoResolve(ctx) ?? const SigningConfig();
  if (!configured.isConfigured && ctx.mode.isRelease) {
    print(
      '⚠️  No signing configuration found — signing the AAB with the DEBUG '
      'keystore. Store uploads will be rejected.',
    );
  }
  await signAab(
    unsignedAabPath: unsignedBundle,
    keystorePath: configured.isConfigured
        ? configured.keystorePath
        : await debugKeystore(processRunner: processRunner),
    keyAlias: configured.isConfigured ? configured.keyAlias : 'androiddebugkey',
    storePass: configured.isConfigured ? configured.storePassword : 'android',
    signedAabPath: signedBundle,
    jarsignerPath: await findJarsigner(toolchain, processRunner: processRunner),
  );
}

Future<String?> findJarsigner(
  ResolvedToolchain toolchain, {
  AndroidProcessRunner processRunner = runAndroidProcess,
}) async {
  try {
    final javac = await toolchain.findJavac();
    final candidate = p.join(p.dirname(javac), 'jarsigner');
    if (await File(candidate).exists()) return candidate;
  } catch (_) {}
  try {
    final result = await processRunner('which', ['jarsigner']);
    if (result.exitCode == 0) return (result.stdout as String).trim();
  } catch (_) {}
  return null;
}

Future<String> debugKeystore({
  AndroidProcessRunner processRunner = runAndroidProcess,
}) async {
  final path = p.join(
    Platform.environment['HOME'] ?? '',
    '.android',
    'debug.keystore',
  );
  if (await File(path).exists()) return path;
  await Directory(p.dirname(path)).create(recursive: true);
  final result = await processRunner('keytool', [
    '-genkey',
    '-v',
    '-keystore',
    path,
    '-storepass',
    'android',
    '-alias',
    'androiddebugkey',
    '-keypass',
    'android',
    '-keyalg',
    'RSA',
    '-keysize',
    '2048',
    '-validity',
    '10000',
    '-dname',
    'CN=Android Debug,O=Android,C=US',
  ]);
  if (result.exitCode != 0) {
    throw Exception('keytool failed: ${result.stderr}');
  }
  return path;
}
