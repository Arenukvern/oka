# Changelog

## 0.13.1

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
## 0.13.0

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
- Updated `oka_core` dependency constraint to `^0.14.0`.
## 0.12.1

### Patch Changes

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
All notable changes to this package are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

## 0.5.0

- Join the complete package release train at `0.5.0` (android release
  engine-pairing fix; see the main `oka` changelog). Add a package README.

## 0.4.0

- Version alignment with the 0.4.0 oka release train; no functional changes in this package.



