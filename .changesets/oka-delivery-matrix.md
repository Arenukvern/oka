---
'oka_core': minor
'oka_android': minor
'oka_web': minor
'oka_desktop': minor
'oka_service': minor
'oka_store': minor
'oka': patch
'oka_huawei': minor
'oka_play': minor
'oka_rustore': patch
'oka_conformance': patch
'oka_artifacts': patch
'oka_dart_kernel': patch
'oka_supervisor': patch
'oka_verify': patch
---

**Identity + law hardening (2026-11-22 review wave)**:

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
