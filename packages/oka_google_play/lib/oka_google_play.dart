/// The Google Play STORE package for oka (ADR-0055, ADR-0056).
///
/// A store package is the store's identity plus its publish channel —
/// never a platform. The platform half (the `gms` overlay that folds the
/// Google SDK groups into an Android build) is a delivery decision
/// composed with `oka_android`/`oka_core` overlays; this package only
/// names the store and publishes to it.
///
/// ## The store key
///
/// ```dart
/// import 'package:oka_google_play/oka_google_play.dart';
///
/// const play = storeKeyGooglePlay; // StoreKey('google-play')
/// ```
///
/// The key is a convenience constant (ADR-0056: store packages carry their
/// own key; there is no central registry). A build-side composition may
/// import it freely; a runtime kernel should compose its own
/// `StoreKey('google-play')` instead of pulling channel machinery into the
/// binary just to name a store.
///
/// ## The publish channel
///
/// `PlayPublishTarget` composes the Play Publisher API upload tail (Edits
/// flow: create edit → upload AAB → assign track → commit) onto any oka
/// Android AAB build. Declared in the project composition root — no CLI
/// changes, ever (ADR-0015 verb/target split):
///
/// ```dart
/// Oka(
///   pipelines: [AndroidPipeline(config: AndroidBuild(packageName: '...'))],
///   targets: [
///     // Dry-run is the default; flip dryRun: false to upload for real.
///     PlayPublishTarget(
///       packageName: 'dev.example.app',
///       // dryRun: false,
///       // serviceAccountPath: 'credentials/play-sa.json', // path only
///     ),
///   ],
/// )
/// ```
///
/// The credential is a build-host credential (ADR-0014 three-tier model):
/// the service-account JSON is referenced by *path* (`CredentialRef`) and
/// resolved through the ordered policy (typed-config path →
/// `OKA_PLAY_SERVICE_ACCOUNT_JSON` env var →
/// `~/.oka/credentials/play/service-account-json`). No secret value ever
/// enters `PipelineState`, logs, or plans.
///
/// A full, compiling composition lives in
/// `example/oka_pipeline_example.dart` (the 30-second quickstart in the
/// package README is the same code).
///
/// Conformance (dry-run without credentials, no stdin, no secret values in
/// state) is asserted via the shared suite in `oka_conformance` — see the
/// package README for the one-liner.
library;

export 'src/play_credentials.dart';
export 'src/play_publisher_client.dart';
export 'src/play_store_key.dart';
export 'src/play_target.dart';
export 'src/play_upload_step.dart';
