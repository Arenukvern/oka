# Changelog

## 0.13.2

### Patch Changes

- **Release-train smoke cut, part 2: explicit patch bumps for the 12
  published packages the core cascade does not reach.** The engine's
  dependent cascade is constraint-driven — caret constraints absorb a
  patch bump of `oka_core`, so dependents are skipped by design
  (`if (constraint.allows(newVersion)) continue;`). A full-train smoke
  needs every package declared explicitly. Union with
  `train-smoke-patterns.md` covers all 17 published packages; the three
  unpublished ones (`oka_devices`, `oka_dart_kernel`, `oka_verify`) stay
  out — they have no pub.dev automated-publishing config yet.
## 0.13.1

### Patch Changes

- Updated `oka_core` dependency constraint to `^0.14.0`.
## 0.13.0

### Minor Changes

- **Identity + law hardening (2026-11-22 review wave)**:
  
  - **`oka_store`**: `StoreKey.of` (runtime-checked factory for dynamic
    boundaries — the const ctor cannot validate), the erasure caveat
    documented (a key IS its String at runtime), and `okaStoreDefine`
    (`OKA_STORE`) — the dart-define key under which a delivery variant
    bakes its store key into the compiled binary.
  - **`oka_core`**: `Variant.applyTo` now bakes `OKA_STORE=<key.name>` so
    the store identity reaches the artifact and the app boot can verify
    its runtime binding matches the composition (no two-masters drift).
    `DeliveryTarget.dartDefines` contributes nothing — the variant is the
    single define writer (the target-level getter remains the general
    ADR-0014 surface for plain targets). The dispatcher applies
    `transformContext` BEFORE the build directory resolves, so a
    delivery's `buildAab` lands in the same `-aab` directory convention
    bare `--aab` builds use, and `--aab` alongside a delivery warns
    loudly instead of being silently overridden (artifact format is
    composition-owned). `PublishTarget.validateDelivery` now requires
    every parameter — a partial call can no longer silently skip the
    overlay legality checks. Target runs whose final step is not the
    artifact build still print a completion line.
  - **`oka_play`**: the Play channel REQUIRES the `gms` overlay on
    deliveries (Play presumes GMS; the overlay may be an empty marker —
    the declaration is the contract).
  - **`oka_desktop`**: desktop pipelines forward `ctx.flavor` (never
    silently dropped) and fail the step when flutter exits green but the
    expected artifact directory is missing.
  - **`oka_huawei`**: `HuaweiPublishTarget` is variant-free — the channel
    no longer restates the build config (ADR-0055: channels publish,
    deliveries build); the opt-in `verifyArtifact` gate derives its
    exclusion set from the delivery context's overlays. `HuaweiBuildVariant`
    stays exported for legacy compositions.
  
  **oka_core**: ADR-0055 — the delivery matrix. New `Delivery`/`DeliveryTarget`
  (pipeline by const reference + variant + channel), `Variant` (entrypoint,
  defines, overlays, open `StoreKey`), `Overlay` (defines + native-dep edits),
  `RunPipelineStep`; `Target.dartDefines` (ADR-0014 amendment — CLI wins) and
  `Target.transformContext`; `Oka.pipelines` optional (delivery-only projects);
  `BuildContext.overlays`; `PublishTarget` capability hooks
  (`acceptedPlatforms`, `acceptedArtifactFormats`, `requiredOverlays`,
  `prohibitedOverlays`) with `validateDelivery` composition checks.
  
  **oka_store**: new leaf package — the open store-key identity (`StoreKey`
  extension type + validation, `StoreBinding` + `NoopStoreBinding`, well-known
  keys as convenience constants, no enum).
  
  **oka_android**: overlay native-dependency folding
  (`foldOverlayDependencies` — the generic form of the GMS exclusion).
  
  **oka_web**: new `WebPipeline` (validate → emit shell → flutter build web);
  `WebBuildTarget.transformContext` wires contribution dartDefines into the
  build (previously dead); gh-pages/itch declare platform/format capabilities.
  
  **oka_desktop**: new — `MacosPipeline`/`LinuxPipeline`/`WindowsPipeline`
  (honest `flutter build <desktop>` delegation, delivery-ready).
  
  **oka_service**: new — `CommandPipeline` (jaspr/dart/docker/any argv) +
  `GitHubReleasePublishTarget` (gh CLI, ambient auth) + `StageFileStep`.
  
  Store channels declare capabilities (Play: android/aab; RuStore: android;
  AppGallery: android/aab, `gms` overlay prohibited). ADR 0055.
- Updated `oka_core` dependency constraint to `^0.14.0`.
## 0.12.0

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.11.0

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.10.3

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.10.2

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.10.1

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.10.0

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.8.1

- Part of the 0.8.1 train: usage-banner and doctor doc-pointer fixes in the
  `oka` CLI; no package-specific changes in this package.

## 0.8.0

- Part of the 0.8.0 train: Dart SDK floors ^3.13.0 (extraneous `final` parameter modifiers dropped); no package-specific changes.

## 0.7.0

- Release train alignment with `oka` 0.7.0.

## 0.4.0

- Version alignment with the 0.4.0 oka release train; no functional changes in this package.


## 0.2.0

- Add browser profile diagnostics and persist profile paths/session names in
  Chrome leases for attribution, including temporary profiles.

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



