/// Example 03 — release-ready config: env-based signing, versioning,
/// R8 defaults. See this project's README for the release commands.
library;

import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:oka_core/oka_core.dart';

Future<void> main(List<String> args) => okaRun(
  args,
  oka: Oka(
    pipelines: [
      AndroidPipeline(
        config: const AndroidBuild(
          name: 'release_oka',
          packageName: 'com.example.release_oka',
          minSdk: '23',
          targetSdk: '34',
          compileSdk: '34',
          // Store listings track this — bump every release:
          versionCode: 1,
          versionName: '1.0.0',
          // Release shrinks by default (R8); mapping.txt lands in
          // <buildDir>/r8/. Project rules:
          // proguardFiles: ['android/proguard-rules.pro'],
        ),
        overrides: PipelineOverrides(
          // Release keystore, resolved from the environment — never
          // hardcoded. Without it, release builds fall back to the
          // debug keystore with a loud warning (stores reject that).
          signing: SigningConfig(
            keystorePath: 'keys/release.jks',
            keyAlias: 'upload',
            storePassword: Platform.environment['OKA_STORE_PASS'] ?? '',
            keyPassword: Platform.environment['OKA_KEY_PASS'] ?? '',
          ),
        ),
        steps: [...AndroidPipeline.defaultSteps],
      ),
    ],
    targets: [
      DeviceTarget(),
      // `oka run verify` — the ADR-0029 ladder: provenance → pairing →
      // install → device health → launch → Dart main() → first frame.
      VerifyTarget(),
    ],
  ),
);
