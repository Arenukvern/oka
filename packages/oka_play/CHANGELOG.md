## 0.12.2

### Patch Changes

- **oka_core**: ADR-0055 — the delivery matrix. New `Delivery`/`DeliveryTarget`
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
- Updated `oka_android` dependency constraint to `^0.14.0`.
- Updated `oka_core` dependency constraint to `^0.14.0`.
## 0.12.0 <!-- x-release-please-version -->

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

## 0.2.0

- Join the complete package release train with compatible `0.2.0` internal
  dependency constraints.

## 0.4.0

- Version alignment with the 0.4.0 oka release train; no functional changes in this package.

## 0.1.6

- Initial release (ADR-0014 P1): `PlayPublishTarget` (`PublishTarget`
  implementation) with dry-run-by-default plans, `PlayTrack` typed config
  (internal default), staged-rollout `userFraction`, service-account
  credential by path via the ordered `CredentialResolver` policy
  (`OKA_PLAY_SERVICE_ACCOUNT_JSON`), the androidpublisher/v3 Edits flow
  (`PlayPublisherClient`: create edit → upload AAB → assign track →
  commit), and JWT → OAuth token exchange through googleapis_auth over an
  injectable transport (tests run fully offline).
