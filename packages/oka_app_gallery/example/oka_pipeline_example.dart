/// The 30-second oka_app_gallery quickstart, as a real, compiling file.
///
/// This IS a minimal `tool/oka_pipeline.dart` (ADR-0010 — the project is
/// the config): the Android platform pipeline plus the AppGallery Connect
/// publish target ([AppGalleryPublishTarget]) in the same `Oka(...)`
/// composition root. One codebase, many stores: the *same* pipeline
/// composes Google Play (`oka_google_play`) and RuStore (`oka_rustore`) —
/// a store is a channel, never a platform fork (ADR-0055/0056). The
/// GMS-free build posture for Huawei devices is the DELIVERY's business
/// (`hms-free` overlay via `oka_android`; `oka_huawei` documents the
/// platform half).
///
/// Run it from the project root:
///
/// ```bash
/// oka explain --targets          # validated step chains, nothing executes
/// oka run publish-app-gallery    # dry-run (the default): plan, zero HTTP
/// oka run publish-app-gallery    # with dryRun: false below → real upload
/// ```
///
/// **Dry-run first.** `AppGalleryPublishTarget` defaults to `dryRun: true`:
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
import 'package:oka_app_gallery/oka_app_gallery.dart';

const androidBuild = AndroidBuild(packageName: 'dev.example.app');


Future<void> main(List<String> args) => okaRun(
      args,
      oka: const Oka(
        pipelines: [
          AndroidPipeline(config: androidBuild),
        ],
        targets: [
          // The publish target. Target names are unique per project
          // (ADR-0015), so this is ONE target: `publish-app-gallery` in
          // dry-run mode today, and the same value with `dryRun: false`
          // when you are ready to upload for real.
          AppGalleryPublishTarget(
            release: AppGalleryReleaseConfig(
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
