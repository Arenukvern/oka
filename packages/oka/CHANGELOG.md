# Changelog

<!-- markdownlint-disable MD052 -->

All notable changes to the Oka project will be documented in this file.

## [1.0.0](https://github.com/Arenukvern/oka/compare/v0.1.6...v1.0.0) (2026-09-10)


### ⚠ BREAKING CHANGES

* none for API consumers — additive (AndroidBuild/FlutterBuild, configOverrides). example/oka.yaml removed (hook is the config); yaml projects unaffected.
* CargoApkConfig/CargoApkManifest removed from oka_core and oka_android public barrels; oka.yaml cargo_apk key is no longer read.

### Features

* aab ([e43ddf3](https://github.com/Arenukvern/oka/commit/e43ddf30bc08614497187458bcb138fd79c29a5f))
* aab ([640d978](https://github.com/Arenukvern/oka/commit/640d9788e069f9938d7daa8b395fbaeaa6bf036b))
* aar ([152cd90](https://github.com/Arenukvern/oka/commit/152cd9082ace4022043a94ca22ec21123cb308f4))
* adopt last_answer on full-Dart config; adoption hardening (ADR-0010) ([1799a73](https://github.com/Arenukvern/oka/commit/1799a73b621bd03fdb4dc57e4c0bc862ebadc414))
* artifact store + cache unification (T0), Target contract + oka run dispatcher (C0) ([c300e26](https://github.com/Arenukvern/oka/commit/c300e26ec170bf6e1a0e3afd616a7dff0069dae3))
* assets ([a4b9a15](https://github.com/Arenukvern/oka/commit/a4b9a15ed5d844c5bc14081bcc51b586795b9e80))
* assets ([23af7db](https://github.com/Arenukvern/oka/commit/23af7db8c3b819eead426e35238789e0054f4bc4))
* cleanup ([9e3bd3f](https://github.com/Arenukvern/oka/commit/9e3bd3fa1aaf15285f520e4d4132e15988ebaf40))
* complete no-Gradle plugin packaging and multi-dex support ([ef24651](https://github.com/Arenukvern/oka/commit/ef24651c0cb4137a759d37951df449c3add9593e))
* conform to Dart dev session contract spec v2 (.flutter_mcp/runner-session.json) ([eea654e](https://github.com/Arenukvern/oka/commit/eea654e3264d76c1465058b0696dcb133ace24cf))
* dev-session vm.uri artifact + hot-restart relaunch fallback (ADR-0011 follow-ups) ([09116dc](https://github.com/Arenukvern/oka/commit/09116dcf46296d2ec4dcdc419be69fadeb88c3f9))
* device layer through the store (T2) ([3fbef4c](https://github.com/Arenukvern/oka/commit/3fbef4c7802b12b9975bcdb65ebd1876fec83c5d))
* EmulatorTarget — emulator lifecycle in the composition API (ADR-0013/0015) ([9af5d61](https://github.com/Arenukvern/oka/commit/9af5d6104be4cfa244ed67d18b811b1e41dd37ab))
* **explain:** dependency-plan dry-run via oka explain --deps (ADR-0008) ([129cebb](https://github.com/Arenukvern/oka/commit/129cebbb6b0f4229e40c45430b8e01824d60b593))
* H0-H2 hot-reload prerequisites, run session manifest, device-layer e2e (ADR-0011) ([05b57e0](https://github.com/Arenukvern/oka/commit/05b57e05f17427644e5ef5a5c2ee5558ec31d558))
* H3-H5 dev loop — daemon session, watch classification, hot restart, doctor (ADR-0011) ([0a201a7](https://github.com/Arenukvern/oka/commit/0a201a7490597341eeec1eef77fcd52562919641))
* **init:** full-Dart scaffold by default; multi-dex determinism; OSS publish readiness ([05e27fd](https://github.com/Arenukvern/oka/commit/05e27fdbfef23b0eb815d7e7fc347d3d58864b30))
* it works! ([2cfc74c](https://github.com/Arenukvern/oka/commit/2cfc74cf85b3d6c7b3d3b141cd43a865fc5b04c4))
* maven resolver ([0fc8018](https://github.com/Arenukvern/oka/commit/0fc8018dd26e74a0975da2867b46f26b078332c7))
* oka_play + oka_conformance (P1), oka_huawei + GMS-exclusion validation (P2) ([0d7d07e](https://github.com/Arenukvern/oka/commit/0d7d07e0972d5f31ae375fb7d40c9d9b62a534ee))
* oss setup ([b19a7ca](https://github.com/Arenukvern/oka/commit/b19a7ca7804d0e392ce435fe8362ff361cb5b6e7))
* plan ([9731f99](https://github.com/Arenukvern/oka/commit/9731f99ac9baaafba4edc01348f0ca607e1d8243))
* prepared for oss ([6d047cb](https://github.com/Arenukvern/oka/commit/6d047cb0a025c4f1d2152cc01186dfd9a1140af1))
* process leases ([3563eeb](https://github.com/Arenukvern/oka/commit/3563eeb4f74b6163c7d762501730d29e80075584))
* PublishTarget contract + credential-path policy + doctor secret audit (P0) ([bd75c80](https://github.com/Arenukvern/oka/commit/bd75c80ce3e555218d9cb3af8decc1cc665cf79b))
* stewarship ([337b913](https://github.com/Arenukvern/oka/commit/337b9134aee00d21372c92ea0f9500358b1e5f3e))
* toolchain resolution as data (T1), platform leakage folded behind targets (C1), explain --targets (C2) ([d52aea4](https://github.com/Arenukvern/oka/commit/d52aea4d6ba93c57d8088823d7fd4f8be04076a5))
* typed per-project Dart config — oka.yaml optional (ADR-0010) ([8d905c6](https://github.com/Arenukvern/oka/commit/8d905c6164c2f47611c46e556aa3efee922c4d17))
* web + crazygames ([e666846](https://github.com/Arenukvern/oka/commit/e66684678a56865db08144eea00d764409df28ab))
* web configs ([16fdc12](https://github.com/Arenukvern/oka/commit/16fdc12246b5406119057a884e5406172d15538c))
* web target ([d1d8d15](https://github.com/Arenukvern/oka/commit/d1d8d1528f9aa5548b532eab93901a2ee18ed9b4))
* web target docs ([c0e7cd5](https://github.com/Arenukvern/oka/commit/c0e7cd5c83ea18ccbc21c88cb5fd76e1efe3a6f5))


### Bug Fixes

* a ([cacd1e1](https://github.com/Arenukvern/oka/commit/cacd1e1fecd9e664e8c32c45724d379e7e30303e))
* add packages/oka README (pub validation requires one) ([0dd91e1](https://github.com/Arenukvern/oka/commit/0dd91e1733a9790ef8c2ec9195dee4773a3d2043))
* apk and aab ([f5a5cf1](https://github.com/Arenukvern/oka/commit/f5a5cf18a9c05c4e1d3904bbe449b8a38ebeaf16))
* assets ([585d069](https://github.com/Arenukvern/oka/commit/585d069d9b09c4bdfe4f51e1aef2989c6e4f64ec))
* build ([218bd44](https://github.com/Arenukvern/oka/commit/218bd44c31143da1ea34dd562416aecd7c44a537))
* build versio ([ef7c9cf](https://github.com/Arenukvern/oka/commit/ef7c9cf2065868b5ae691694aa82e05fb048476a))
* ci — skip example resolution under plain dart, allow-list synthetic test key, zero analyzer infos ([6ee4753](https://github.com/Arenukvern/oka/commit/6ee4753d72f4ebc77542992f93ded3db839fcdfb))
* compile bugs ([9b849f5](https://github.com/Arenukvern/oka/commit/9b849f5611a35abb6166cfae1d065703825f87ba))
* device serial selection across the device layer (multi-device hosts) ([c8021f3](https://github.com/Arenukvern/oka/commit/c8021f36184c83fc4a000dea7755e6aae0b1895b))
* license an analysis ([c99c355](https://github.com/Arenukvern/oka/commit/c99c35506282f3ae81f0059cb7e673dba49fe81f))
* r8 ([f3eeb10](https://github.com/Arenukvern/oka/commit/f3eeb1036dd57240227b93ee6b3c163a95f4da35))
* readme ([4328ccf](https://github.com/Arenukvern/oka/commit/4328ccf6b711ff171e93c8fad0a0898739c89602))
* readme ([0cf5afe](https://github.com/Arenukvern/oka/commit/0cf5afe50f27726377973fa0f6219f7cf688097c))
* readme & docs ([2490d40](https://github.com/Arenukvern/oka/commit/2490d40b04ddd9ce704b422445ff46dbcb3705a3))
* skip adb/emulator-dependent BootEmulatorStep tests when binaries are absent (CI without Android SDK) ([84178af](https://github.com/Arenukvern/oka/commit/84178af58665e5c756ee90e75fb5b9281efb7470))
* versions ([42e4c88](https://github.com/Arenukvern/oka/commit/42e4c880937cfa25a943fa4d30947525e558ff5a))
* VM-service ws endpoint normalization (+/ws) for http-only announcements; control-port default ([452fd8d](https://github.com/Arenukvern/oka/commit/452fd8dba33f0ad8f63e74ca4f37323767d31c60))
* yaml parsing ([aedcf9b](https://github.com/Arenukvern/oka/commit/aedcf9bbba9a3eadfeafc9fc5dedf57af9b26c7d))


### Documentation

* ADR-0014 distribution targets + three-tier secrets model; P0-P2 phase items ([47b67ac](https://github.com/Arenukvern/oka/commit/47b67accb8fd38419148f6329ed9754a652d42a9))
* ADR-0015 CLI verb/target split; C0-C2 phase items, FAQ, north star ([92a11b7](https://github.com/Arenukvern/oka/commit/92a11b74cce43e5483d41e4cc9f9121e29cc19ca))
* **adr:** propose typed per-project Dart config (ADR-0010) ([4569aa7](https://github.com/Arenukvern/oka/commit/4569aa708c88155be41a1f24925a5e7dcc93f2df))
* **checklist:** extract open work only; archive completed phases ([764ca6a](https://github.com/Arenukvern/oka/commit/764ca6a9176458e006a89749c74a6850b468cd3d))
* **evidence:** record first steward smoke + build benchmark runs; AGENTS steward workflow ([5ccebb3](https://github.com/Arenukvern/oka/commit/5ccebb39ac8f834ea83a189204bc77a5d742ae9e))
* north-star framing — declarative, compositional, AI-native; Android first ([96af0f3](https://github.com/Arenukvern/oka/commit/96af0f3d1b31c8331d54f0e0511b282baf674f1b))
* oka_web dartdoc polish ([0562943](https://github.com/Arenukvern/oka/commit/0562943d6325aaf49e5f1eb74d769a3dadeb6199))
* reframe the why — lock-in and unmanageability, not slowness ([e0370ed](https://github.com/Arenukvern/oka/commit/e0370ed4c4041a5e315e93409dbda326a4a914e6))
* roadmap — oka dev control-port prerequisite for mcp_flutter delegation; emulator target landed ([e87d12f](https://github.com/Arenukvern/oka/commit/e87d12f3a1624fd1706807180aa97bfd5b07ac24))
* toolchain ([bab2cb6](https://github.com/Arenukvern/oka/commit/bab2cb6e87e1f7557dbfc699f072fe0e897d5d3b))


### Miscellaneous

* remove demoted cargo-apk hybrid completely (ADR-0009) ([63a800a](https://github.com/Arenukvern/oka/commit/63a800a2cf9fb824a767ca77d81c43c16b3e4148))

## [0.1.6] - 2026-07-29

### Added

- **Complete no-Gradle plugin packaging** (`PluginPackager`):
  - Compile plugin Java/Kotlin sources into the app DEX
  - Parse Gradle deps + Maven/AAR resolve with limited POM transitives
  - Generate per-plugin `BuildConfig`
  - CMake/NDK build for `jni` → `libdartjni.so`
  - Real non-empty `GeneratedPluginRegistrant` by default
- d8 classpath: runtime vs compile-only jars; version/KMP artifact dedupe

### Changed

- Default `oka build apk` packages all plugins (no empty soft-shell registrant)
- `--soft-plugins` hidden escape hatch only

## [0.1.5] - 2026-07-18

### Added

- `oka get android-sdk` / packaging SDK bootstrap under `~/.oka/android-sdk` (cmdline-tools + build-tools 35 + platforms 34–36)
- `oka clean --android-sdk` for oka-managed SDK cleanup
- `--soft-plugins` build flag: skip jni/unsupported hard-fail; soft packaging uses empty plugin registrant
- Prefer oka-managed SDK root / `OKA_ANDROID_SDK` in locator

### Fixed

- Embedding classes extracted for d8 (avoid natives-in-jar)
- Platform jar fallback when compileSdk platform missing
- Metadata-only AndroidX AARs no longer abort dependency resolve

## [0.1.4] - 2026-07-18

### Added

- **No-Gradle Flutter APK pipeline (default `oka build apk`)**
  - `flutter assemble` orchestration (debug/profile/release targets)
  - Host codegen: `MainActivity` + `GeneratedPluginRegistrant`
  - APK layout staging/validation (`classes.dex`, `assets/flutter_assets/**`, `lib/<abi>/libflutter.so`)
  - Engine `libflutter.so` extraction from Flutter SDK `flutter.jar`
  - Minimal AndroidX + AAR `classes.jar` dependency cache (`DependencyCache`)
  - Plugin discovery from `.flutter-plugins-dependencies` with clear unsupported failures
  - Release multi-ABI + `libapp.so` packaging paths
  - Phase checklist: `docs/PHASE_CHECKLIST.mdx`
  - Unit tests under `test/` for all phases

### Changed

- Default build no longer uses cargo-apk hybrid or `flutter build apk` (Gradle) fallback
- `rust_wrapper` demoted; Cargo.toml valid and unused by default
- `--flutter` is a no-op alias; use `--native-android` for legacy non-Flutter pipeline

## [0.1.0] - 2025-01-10

### Added

- **Phase 1: Foundation & AI Infrastructure**

  - Project structure with CLI support
  - Extension type models for configuration (OkaConfig, AndroidConfig, Dependency, etc.)
  - AI agent integration with Apple Foundation Models and Gemini fallback
  - Prompt templates for Gradle conversion and manifest merging
  - Configuration caching system

- **Phase 2: Core Build Pipeline**

  - Android SDK tool locator (aapt2, d8, r8, kotlinc, javac, etc.)
  - APK builder with resource compilation, Kotlin/Java compilation, DEX conversion
  - APK packaging and signing with debug keystore
  - Basic incremental build support

- **CLI Commands**

  - `oka init` - Initialize oka.yaml from Gradle or create default config
  - `oka build apk` - Build debug or release APK
  - `oka doctor` - Check system requirements and configuration
  - `oka clean` - Clean build caches
  - `oka dev` - Stub for development mode (planned)

- **Documentation**
  - README with quick start guide
  - Architecture overview
  - Extension type model patterns
  - Configuration examples

### Known Limitations

- Dev mode (hot reload) not yet implemented
- AAR dependency processing not implemented
- Plugin discovery not implemented
- Manifest merging needs testing
- No AAB (Android App Bundle) support yet

### Next Steps

- Complete Phase 3: Dependency Resolution
- Complete Phase 4: Plugin Integration
- Complete Phase 5: Hot Reload
- Create example app with monetization + crashlytics
- Integration testing
