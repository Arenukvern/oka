/// Google Play publish target for oka (ADR-0014).
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
///     PlayPublishTarget(),                       // dry-run (the default)
///     PlayPublishTarget(
///       dryRun: false,
///       packageName: 'dev.example.app',
///       serviceAccountPath: 'credentials/play-sa.json', // path, not value
///     ),
///   ],
/// )
/// ```
///
/// The credential is a build-host credential (ADR-0014 three-tier model):
/// the service-account JSON is referenced by *path* ([CredentialRef]) and
/// resolved through the ordered policy (typed-config path →
/// `OKA_PLAY_SERVICE_ACCOUNT_JSON` env var →
/// `~/.oka/credentials/play/service-account-json`). No secret value ever
/// enters `PipelineState`, logs, or plans.
///
/// Conformance (dry-run without credentials, no stdin, no secret values in
/// state) is asserted via the shared suite in `oka_conformance` — see the
/// package README for the one-liner.
library;

export 'src/play_credentials.dart';
export 'src/play_publisher_client.dart';
export 'src/play_target.dart';
export 'src/play_upload_step.dart';
