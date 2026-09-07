/// The 30-second oka_play quickstart, as a real, compiling file.
///
/// This IS a minimal `tool/oka_pipeline.dart` (ADR-0010 — the project is
/// the config): an existing oka Android pipeline plus the Google Play
/// publish target composed into the same `Oka(...)` composition root. No
/// CLI changes, no Gradle, no oka.yaml needed.
///
/// Run it from the project root:
///
/// ```bash
/// oka explain --targets     # validated step chains, nothing executes
/// oka run publish-play      # dry-run (the default): plan, zero HTTP
/// oka run publish-play      # with dryRun: false below → real upload
/// ```
///
/// **Dry-run first.** `PlayPublishTarget` defaults to `dryRun: true`: the
/// compiled chain substitutes the upload step with a plan step that prints
/// exactly what a real run would do (endpoint, track, artifact, metadata)
/// and issues no HTTP — it needs no credentials and no AAB on disk. Flip
/// `dryRun: false` (one typed field) only when the plan looks right.
///
/// The credential is referenced **by path only** (ADR-0014 three-tier
/// model). A service-account JSON value never appears in this file, in
/// `oka.yaml`, in git, in state, or in logs. See the README's credential
/// checklist for where the file may live and the exact env var.
library;

import 'package:oka_android/oka_android.dart';
import 'package:oka_play/oka_play.dart';

Future<void> main(final List<String> args) => okaRun(
      args,
      oka: const Oka(
        pipelines: [
          // The Android pipeline you already have — oka_play changes
          // nothing about it. Build the signed bundle with `oka build aab`;
          // the upload tail stages the AAB from oka's default output
          // layout, or from an explicit `artifactPath` you give the target.
          AndroidPipeline(
            config: AndroidBuild(packageName: 'dev.example.app'),
          ),
        ],
        targets: [
          // The publish target. Target names are unique per project
          // (ADR-0015), so this is ONE target: `publish-play` in dry-run
          // mode today, and the same value with `dryRun: false` when you
          // are ready to upload for real.
          PlayPublishTarget(
            packageName: 'dev.example.app',
            // releaseTrack: PlayTrack.internal is the default
            // Dry-run is the default (law 1). To upload for real, flip:
            //
            // dryRun: false,
            // serviceAccountPath: 'credentials/play-sa.json', // PATH only
            //
            // Optional knobs (all typed, all plan-visible in dry-run):
            // userFraction: 0.10,   // staged rollout (0 < x < 1)
            // releaseName: 'Release 42',
            // artifactPath: 'build/app-release-bundle.aab',
          ),
        ],
      ),
    );
