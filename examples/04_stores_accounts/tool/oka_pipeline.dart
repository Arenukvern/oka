/// Example 04 — one codebase, two Play accounts, white-label brands,
/// Huawei + RuStore. The build config is a program: `_brand()` composes a
/// pipeline per brand, `--flavor` picks one, upload targets are values.
///
///   oka build apk --release --flavor acme
///   oka run publish-play-acme        # dry-run plan — zero HTTP, no creds
///
/// Companion guide: docs/guides/accounts_and_stores.mdx
library;

// Uncomment together with the signing block in _brand():
// import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:oka_core/oka_core.dart';
import 'package:oka_huawei/oka_huawei.dart';
import 'package:oka_play/oka_play.dart';
import 'package:oka_rustore/oka_rustore.dart';

/// One branded Android app: own application id, name, icon — own keystore.
/// [keystorePath] and [storePassEnv] feed the commented signing block:
/// uncomment once each brand has its keystore (secrets via env, and one
/// release key per store listing — stable across releases).
AndroidPipeline _brand({
  required String appName,
  required String applicationId,
  required String keystorePath,
  required String storePassEnv,
  required String iconBackground,
}) {
  return AndroidPipeline(
    config: AndroidBuild(
      name: appName,
      packageName: applicationId,
      minSdk: '23',
      targetSdk: '34',
      compileSdk: '34',
      versionCode: 1, // bump per store listing on every release
      versionName: '1.0.0',
      javaVersion: 17,
    ),
    overrides: PipelineOverrides(
      // No vector asset needed — oka generates a glyph on this background.
      icon: IconConfig(backgroundColor: iconBackground),
      // signing: SigningConfig(
      //   keystorePath: keystorePath,
      //   keyAlias: 'upload',
      //   storePassword: Platform.environment[storePassEnv] ?? '',
      //   keyPassword: Platform.environment['${storePassEnv}_KEY'] ?? '',
      // ),
    ),
    steps: [...AndroidPipeline.defaultSteps],
  );
}

/// `--flavor acme` / `--flavor client` (a first-class oka arg).
String _flavor(List<String> args, {required String fallback}) {
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--flavor' && i + 1 < args.length) return args[i + 1];
    if (args[i].startsWith('--flavor=')) return args[i].split('=').last;
  }
  return fallback;
}

Future<void> main(List<String> args) {
  final pipeline = switch (_flavor(args, fallback: 'acme')) {
    'acme' => _brand(
      appName: 'MyApp',
      applicationId: 'com.acme.myapp',
      keystorePath: 'keys/acme.jks',
      storePassEnv: 'OKA_ACME_STORE_PASS',
      iconBackground: '#02569B',
    ),
    'client' => _brand(
      appName: 'ClientApp',
      applicationId: 'com.client.myapp',
      keystorePath: 'keys/client.jks',
      storePassEnv: 'OKA_CLIENT_STORE_PASS',
      iconBackground: '#E8F5E9',
    ),
    final f => throw ArgumentError('unknown flavor: $f'),
  };

  return okaRun(
    args,
    oka: Oka(
      pipelines: [pipeline],
      targets: const [
        DeviceTarget(),
        // ── Your Play account ────────────────────────────────────────────
        PlayPublishTarget(
          targetName: 'publish-play-acme',
          packageName: 'com.acme.myapp',
          serviceAccountPath: 'keys/play-acme.json',
          releaseTrack: PlayTrack.production,
        ),
        // ── Client's Play account (white-label) ─────────────────────────
        PlayPublishTarget(
          targetName: 'publish-play-client',
          packageName: 'com.client.myapp',
          serviceAccountPath: 'keys/play-client.json',
          releaseTrack: PlayTrack.internal,
        ),
        // ── Huawei AppGallery: builds the GMS-free variant + upload tail ─
        HuaweiPublishTarget(
          targetName: 'publish-huawei',
          release: HuaweiReleaseConfig(
            appId: '110012345', // numeric AGC app id — not a secret
            track: HuaweiReleaseConfig.defaultTrack,
          ),
        ),
        // ── RuStore: readiness + verification (upload needs an adapter) ──
        RuStorePublishTarget(
          targetName: 'publish-rustore',
          packageName: 'com.acme.myapp',
        ),
      ],
    ),
  );
}
