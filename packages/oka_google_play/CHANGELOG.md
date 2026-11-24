# Changelog

## 0.14.0

### Minor Changes

- Raise Dart SDK floor to ^3.14.0 (Flutter 3.50 toolchain).
- Updated `oka_android` dependency constraint to `^0.14.0`.
- Updated `oka_conformance` dependency constraint to `^0.13.0`.
- Updated `oka_core` dependency constraint to `^0.15.0`.
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
All notable changes to `oka_google_play` are documented here. The release
train prepends sections per version — headings start with the exact
version.

## 0.12.0

- New package (ADR-0056 store/platform line): the Google Play STORE
  package — `storeKeyGooglePlay` plus the Play publish channel
  (`PlayPublishTarget`, Play Publisher API Edits-flow upload tail,
  dry-run plans, service-account credentials by path). Succeeds the
  retired `oka_play` package; the store key identity joins the channel in
  one store package.



