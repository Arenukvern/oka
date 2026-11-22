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

- Style: adjacent-string lints in `resource_ids_live_test`.

## 0.8.1

- Part of the 0.8.1 train: usage-banner and doctor doc-pointer fixes in the
  `oka` CLI; no package-specific changes in this package.

## 0.8.0

- Part of the 0.8.0 train: Dart SDK floors ^3.13.0 (extraneous `final` parameter modifiers dropped); no package-specific changes.

## 0.7.0

### Changed

- Release train alignment with `oka` 0.7.0.

## 0.5.0

### Fixed

- Release builds no longer fall back to the debug `flutter.jar` when the
  release jar is missing: the fallback shipped a debug JIT engine with a
  release AOT snapshot, producing apps that hang on the splash screen and
  never run Dart `main()`. Missing jars trigger `flutter precache --android`
  once; a still-missing jar fails the build.

### Changed

- Engine artifact resolution is mode-correct: debug → `android-<abi>`,
  profile → `android-<abi>-profile`, release → `android-<abi>-release`
  (`engineVariantForMode`, `engineArtifactDirForVariant`). The `release`
  boolean parameters on `findFlutterJar` / `extractLibflutter` /
  `extractLibflutterForAbis` were replaced by the variant string, and
  `engineArtifactDirForAbi` was renamed to `engineArtifactDirForVariant`.
- `fingerprintInputs` consumers: `flutter-assemble` and `release-aot`
  fingerprints now include path-dependency sources (`pathDependencyInputs`)
  and `buildArgs`.

## 0.2.0

- Add a composable AVD diagnostics provider with stored configuration,
  userdata/snapshot measurements and recorded session links.

- Join the complete package release train with compatible `0.2.0` internal
  dependency constraints.

## 0.1.6

- Dependency-plan dry-run (`oka explain --deps`), artifact comparison gate
  (`oka compare`), single-step probe support (ADR-0007/0008).
- Conditional gradle dependency dedup (if/else variants collapse to the
  gradle default branch).
- Deterministic packaging: sorted d8 inputs and sorted zip entry order.
- archive ^4 support.

## 0.1.5

- Package split from the oka CLI (ADR-0006).
