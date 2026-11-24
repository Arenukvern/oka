## 0.15.0

### Minor Changes

- Raise Dart SDK floor to ^3.14.0 (Flutter 3.50 toolchain).
- Updated `resource_composition` dependency constraint to `^0.13.0`.
## 0.14.1

### Patch Changes

- **Release-train smoke cut — the first train where every published package
  has its own verified per-package pub.dev tag pattern
  (`<package>-v{{version}}`, repo `Arenukvern/oka`).**
  
  - Automated publishing verified server-side for all 17 published packages;
    `oka_service`, `oka_desktop`, `oka_google_play`, `oka_app_gallery`
    re-enabled after config drift, `oka_update` enabled for the first time.
  - No functional changes: the patch bumps exercise the OIDC publish legs
    end-to-end against the corrected tag patterns.
## 0.14.0

### Minor Changes

- **ADR-0056 — the store/platform line: one package per store, one package
  per platform.** A platform is what the binary runs against (device/runtime
  capability surface); a store is where it ships (distribution/purchase
  channel). The line is one-directional: stores declare platform
  requirements (`requiredOverlays`/`prohibitedOverlays`); platforms never
  name stores. A Huawei device carries AppGallery, RuStore, and sideloaded
  APKs alike.
  
  - **`oka_store` → retired; `oka_play` → retired.** The store-neutral
    identity package and the channel-only Play package are replaced by
    coherent store packages.
  - **`oka_core`**: now owns the open store identity — `StoreKey`,
    `StoreKey.of`, `StoreBinding`, `NoopStoreBinding`, `storeKeyNoop`,
    `okaStoreDefine`. The central `known_stores.dart` registry dissolved:
    each store package carries its own key constant; any other key is a
    plain `StoreKey('my-market')` composed by the project. Runtime kernels
    must not depend on channel packages just to name a store.
  - **`oka_google_play`** (new pub.dev identity): the Google Play STORE
    package — `storeKeyGooglePlay` + the Play publish channel
    (`PlayPublishTarget`, Edits-flow upload tail, credentials by path).
  - **`oka_app_gallery`** (new pub.dev identity): the AppGallery STORE
    package, carved out of `oka_huawei` — `storeKeyAppGallery` +
    `AppGalleryPublishTarget` (was `HuaweiPublishTarget`), the AGC REST
    upload tail, release config, distribution policy; step names are
    store-named (`appgallery-stage-aab`, `appgallery-verify-artifact`);
    the AGC credential policy moved with the store:
    `appgallery/agconnect-credentials`, `OKA_APPGALLERY_AGCONNECT_CREDENTIALS`.
  - **`oka_huawei`**: now the Huawei DEVICE platform package only — the
    GMS-excluding `HuaweiBuildVariant` (GMS-free `extraDeps` filtering +
    composition-time required-artifact rejection). The publish channel and
    AGC machinery moved to `oka_app_gallery`.
  - **`oka_rustore`**: gains `storeKeyRuStore` beside its channel.
  - **Architecture gate** (`tool/contracts/check_architecture.dart`): store
    packages must not depend on each other or on platform packages;
    platform packages must never name stores.
  - **Dependency law**: store-adjacent ecosystem packages (xsoulspace
    monetization, installation-store) must NOT depend on oka store packages
    — only when they genuinely depend on that store's services. The string
    key joined by the `OKA_STORE` define is the ecosystem contract.
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

- Dependency lockfile hygiene (`fix: locks`).

## 0.8.1

- Part of the 0.8.1 train: usage-banner and doctor doc-pointer fixes in the
  `oka` CLI; no package-specific changes in this package.

## 0.8.0

- Bound aggregate direct process observations with configurable
  `observationBudget` (default two seconds); count startup identity time against
  the run deadline and refuse signals when startup identity is unavailable.
  Late readonly results cannot resume an expired stop; kill adapters remain
  awaited and adapter resource cleanup remains their responsibility.

- Return failed deadline teardown receipts while a root remains unresolved,
  preserving its captured identity and explicit `rootExitObserved`; avoid
  waiting indefinitely after returned discovery failure. Timeout diagnostics
  distinguish verified cleanup from unverified survivors (ADR-0046).
  Keep bounded output draining until unresolved root exit so closing a live
  writer's pipe cannot become an accidental termination path. Expose the
  existing process platform seams on `SystemProcessRunner` for composition.

- Retain pre-signal descendants across reparenting; bind each teardown signal
  to its captured identity, and report post-signal discovery loss as unknown.
- Await deadline tree teardown in `runBoundedProcess` after root exit; expose
  `teardownVerified` and unverified cleanup details instead of a premature
  empty-survivor result.

- Stop a newly spawned managed process when its lease cannot be persisted;
  report the original persistence error and whether teardown was verified.
  Refuse startup-failure signals when the live root has no captured identity.

- Add explicit `LeasedProcessProvider.runToExit` for job completion: await exit zero,
  fail nonzero exits, and stop the owned tree on cancellation.
- Keep ready service output drained until process exit; retain leases after an
  unverified stop and protect replacement leases from stale cleanup. Inspection
  now distinguishes matching, recycled and unverifiable process identities.
## 0.7.0

### Changed

- Release train alignment with `oka` 0.7.0.

## 0.4.0

### Added

- `AndroidBuild.r8Rules` (`android.r8_rules`): inline, per-app R8/ProGuard
  rules applied after `proguard_files`; vendor-neutral platform defaults.

- Tree-aware process seam (ADR-0026 decision 8): `ProcessTreeProbe` /
  `HostProcessTreeProbe` descendant enumeration, `stopProcessTree`
  (enumerate before the first signal; graceful→force ladder; verified
  death; recycled-root refusal), and `runBoundedProcess` — a bounded run
  whose deadline kills the spawned tree instead of abandoning it, with
  bounded output capture and a terminal cause.

### Changed

- `SystemProcessRunner` deadline enforcement now kills the child process
  tree before raising `TimeoutException`; the exception contract is
  unchanged, but no child is abandoned on timeout.

## 0.2.0

- Add composable `CacheDiagnostics` providers, typed reports and partial,
  read-only registry inspection. PID-zero leases remain unknown and preserved.

- Add a persistent cache project registry, best-effort build registration and
  saved cleanup plans that revalidate current ownership and filesystem state.

- Add platform-neutral storage inventory and preview/apply pruning contracts,
  with overlap accounting, protected locations and filesystem safety checks.
- Fix absent-store GC, include extracted payload bytes and count only successful
  deletions; reject sweep paths that escape the shared store.

- Release the platform-neutral `Target.explainDetails` hook used by web targets.

- Directory-artifact convention (ADR-0016 W2): `PublishTarget.artifactIsDirectory`
  (default `false` — file targets unchanged) and `PublishPlan.artifactIsDirectory`
  (typed flag in plans, JSON round-trip, `describeLines` marks
  `artifact … (directory)`). `auditPublishConformance` now asserts the
  declared artifact kind when the artifact path exists on disk: a
  directory-artifact target must point at a directory, a file target must
  not point at a directory.

## 0.1.6

- Typed `AndroidBuild`/`FlutterBuild` config values with `copyWith` and
  `toConfigMap` (ADR-0010); `PlatformPipeline.configOverrides` seam and
  `mergeConfigMaps` precedence (Dart config > oka.yaml > defaults).
- `Pipeline.run` accepts a pre-seeded `PipelineState` (runtime scope).
- Entry-point discovery helper (`findPipelineEntrypoint`).

## 0.1.5

- Declarative composition root (`Oka`, `PlatformPipeline`), typed artifact
  pipeline, `okaRun` entrypoint (ADR-0006).
