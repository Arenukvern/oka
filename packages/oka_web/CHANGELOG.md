# Changelog

## 0.2.0

Initial release (ADR-0016 — the web shell station). Publishes on the
release train together with `oka_core` 0.2.0, which introduces the
platform-agnostic `Target.explainDetails` extension point this package's
targets use — publish only after the train lands, never against hosted
`oka_core` 0.1.x.

- **Typed shell values**: `WebShellSpec`, `WebIconSpec`,
  `PwaManifestSpec`/`PwaManifestOverride`, `WebShellContribution` +
  `SimpleWebShellContribution` (the store "what" seam), sealed head/body
  entry types with declarative phases (`WebHeadPhase`:
  `preconnect` → `storeSdk` → `app`) and `requiredSdkGlobal` metadata on
  script entries (the build-time counterpart of the runtime adapters'
  `expectedSdkGlobal`).
- **The emitter "how" seam**: `ShellEmitter` with declared `ownedPaths`;
  `GenerateShellEmitter` (default — owns `web/index.html` +
  `web/manifest.json`, generated-content banners; Flutter
  template-version coupling contained in this one class) and
  `InjectShellEmitter` (marker-based injection for hand-maintained
  `index.html`; fails actionably when markers are absent; never rewrites
  unowned regions).
- **Targets**: `web-shell` (compose + emit, no Flutter invocation) and
  `web-build` (an honest, named delegation to `flutter build web` —
  web is explicitly NOT a `PlatformPipeline`).
- **Drift gate**: pure `checkShellDrift` / `ShellDriftReport`
  comparator over emitter-owned regions, wired as a post-emit
  idempotency check in `EmitWebShellStep`; `WebScriptEntry.toString()`
  renders `requiredSdkGlobal` so `oka explain` surfaces it.
- **Deploy targets** (`PublishTarget`s over the directory-artifact
  convention, `artifactIsDirectory` asserted by the publish conformance
  suite; both **dry-run by default**): `GhPagesDeployTarget`
  (`publish-gh-pages` — git-worktree deploy with ambient git auth only,
  prompt-free git env, allow-empty commits disabled as code) and
  `ItchDeployTarget` (`publish-itch` — `butler push DIR USER/GAME:CHANNEL`,
  API key surfaced only as a redacting `CredentialRef`; the value is
  never logged or stored). `StageWebDirectoryStep` stages the directory
  artifact (typed override → state → `<project>/build/web`).
- **Flagship example**: `example/crazygames/` — the third-party pattern
  pilot (a store package ships exactly this const shape alongside its
  runtime adapter), with SDK-script global reconciled against the
  runtime adapter's `expectedSdkGlobal`.
