/// The 30-second oka_huawei quickstart, as a real, compiling file.
///
/// This IS a minimal `tool/oka_pipeline.dart` (ADR-0010 — the project is
/// the config): the GMS-excluding Android build variant
/// ([HuaweiBuildVariant]) composed as the platform pipeline, plus the
/// AppGallery Connect publish target ([HuaweiPublishTarget]) in the same
/// `Oka(...)` composition root. One codebase, two store targets:
/// `oka_play` composes the *same* pipeline for Google Play — a store
/// target is never a platform fork (ADR-0013 two-axis law).
///
/// Run it from the project root:
///
/// ```bash
/// oka explain --targets     # validated step chains, nothing executes
/// oka run publish-huawei    # dry-run (the default): plan, zero HTTP
/// oka run publish-huawei    # with dryRun: false below → real upload
/// ```
///
/// **Dry-run first.** `HuaweiPublishTarget` defaults to `dryRun: true`:
/// the compiled chain substitutes the upload step with a plan step that
/// prints exactly what a real run would do (endpoint, track, artifact,
/// metadata) and issues no HTTP — no credentials, no AAB, no network.
///
/// The credential is referenced **by path only** (ADR-0014 three-tier
/// model). The AGC API-client secret never appears in this file, in
/// `oka.yaml`, in git, in state, or in logs. See the README's credential
/// checklist for where the file may live and the exact env var.
library;

import 'package:oka_android/oka_android.dart';
import 'package:oka_huawei/oka_huawei.dart';

/// The GMS-excluding build variant: the Android config AppGallery builds
/// ship with. GMS-provided coordinates in `extraDeps` (Play Services,
/// Billing, Ads, Firebase) are dropped from the composed pipeline, and a
/// step *requiring* a GMS-provided artifact fails validation at
/// composition time — before any tool runs.
const HuaweiBuildVariant variant = HuaweiBuildVariant(
  android: AndroidBuild(packageName: 'dev.example.app'),
  overrides: PipelineOverrides(
    extraDeps: [
      'androidx.core:core-ktx:1.13.1',              // kept (not GMS)
      'com.android.billingclient:billing-ktx:7.0.0', // excluded (GMS)
    ],
  ),
);

Future<void> main(final List<String> args) => okaRun(
      args,
      oka: Oka(
        pipelines: [
          // The variant composition: same AndroidBuild you already have,
          // with the GMS-free overrides applied. Nothing else changes.
          AndroidPipeline(
            config: variant.android,
            overrides: variant.gmsFreeOverrides,
          ),
        ],
        targets: [
          // The publish target. Target names are unique per project
          // (ADR-0015), so this is ONE target: `publish-huawei` in dry-run
          // mode today, and the same value with `dryRun: false` when you
          // are ready to upload for real.
          const HuaweiPublishTarget(
            release: HuaweiReleaseConfig(
              appId: '110012345', // AGC console → My apps (not a secret)
              releaseNotes: [
                // Notes are FILE PATHS (tier rule) — never inlined text.
                AgcReleaseNote(language: 'en', file: 'whatsnew-en.txt'),
              ],
            ),
            // Dry-run is the default (law 1). To upload for real, flip:
            //
            // dryRun: false,
            // credentialPath: 'credentials/agconnect.json', // PATH only
          ),
        ],
      ),
    );
