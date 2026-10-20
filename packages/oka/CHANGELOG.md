# Changelog

<!-- markdownlint-disable MD052 -->

All notable changes to the Oka project will be documented in this file.

## [0.8.2](https://github.com/Arenukvern/oka/compare/v0.8.1...v0.8.2) (2026-10-20)


### Bug Fixes

* locks ([83cc8d6](https://github.com/Arenukvern/oka/commit/83cc8d6611511c53651fb7e4dc88d60acdfa2282))

## [0.8.1](https://github.com/Arenukvern/oka/compare/v0.8.0...v0.8.1) (2026-10-18)


### Bug Fixes

* **cli:** align usage banner and doctor doc pointer with the product surface ([d2d5dc3](https://github.com/Arenukvern/oka/commit/d2d5dc34a9b40ecbb20990398dcc2bfb1cd099dd))
* drop extraneous final parameter modifiers in oka_dart_kernel tool scripts ([a973f87](https://github.com/Arenukvern/oka/commit/a973f870bd29555bd84315b880456f0953a05049))


### Documentation

* **evidence:** codemap ADR-0045 live loop first light — supervised worker lifecycle + receipt-backed lane projection; ignore derived .codemap/ ([5c4b052](https://github.com/Arenukvern/oka/commit/5c4b052ec36f1b04cad785d49728f4050e9bee5f))
* realign docs with the four-pillar product north star ([b615650](https://github.com/Arenukvern/oka/commit/b615650e9a576d15cdfcb4753c864632744cd8ad))

## [0.8.0](https://github.com/Arenukvern/oka/compare/v0.7.0...v0.8.0) (2026-10-17)


### Features

* **dev:** composable dev browser and watch inputs (ADR 0044) ([929bc02](https://github.com/Arenukvern/oka/commit/929bc026992dc203dc45126678cd18dbd6f6d24f))
* **oka_core:** failed deadline teardown receipts + process observation budget (ADR 0046) ([d95cf89](https://github.com/Arenukvern/oka/commit/d95cf892e2826be36ed96964e8d21a42cb2ba2af))
* **resource_composition:** ArtifactFresh readiness — artifact-vs-sources freshness ([fc0337f](https://github.com/Arenukvern/oka/commit/fc0337fcf96315a3e22ecd49fcac28740960e5d5))
* **supervisor:** codemap index worker supervision (ADR 0045) ([268eeb2](https://github.com/Arenukvern/oka/commit/268eeb2be415bf87f6c6f0fdd1956abc1b482cea))
* **tool:** native preview probes — native launch + window capture (Swift) ([45dd283](https://github.com/Arenukvern/oka/commit/45dd283fc9a6aa6e7eced5c781e90051c9285ff0))


### Bug Fixes

* Dart 3.13 — SDK floors ^3.13.0, drop extraneous final parameter modifiers ([3f06123](https://github.com/Arenukvern/oka/commit/3f0612310478c288cd8f9f7396538359746486e6))
* **dev:** align oka_dart_kernel workspace constraints with the 0.7.0 train ([d06ded0](https://github.com/Arenukvern/oka/commit/d06ded071d6726d956d1afa8005e867585093672))
* green local gates — analyzer infos and maintainer paths ([adc248a](https://github.com/Arenukvern/oka/commit/adc248a170ab50d1df7226bd1ed73baac0282a7c))
* widen universal_automation_interface to ^0.3.0 in oka_harness/oka_update ([d54d123](https://github.com/Arenukvern/oka/commit/d54d123ee750bda1bf2e9cb03422c491d441705c))


### Documentation

* **skills:** oka-maintenance 1.7.0 — pub.dev publishing runbook ([f857426](https://github.com/Arenukvern/oka/commit/f857426e5386e34a05afc798e43d275c8ddd56e1))

## 0.7.0

### Added

- **Declarative supervisor (ADR-0040/0041).** `oka_supervisor` package:
  crash-only `Supervisor.converge`, plan JSON (`SpecCodec`), advisory
  `MachineRegistry`, and `oka supervisor status|apply|check` CLI verbs.
- **Anchored interval triggers** for supervisor jobs (`IntervalTrigger.at`
  wall-clock anchors).
- **Artifact store (ADR-0043).** `oka_artifacts` with delta chains;
  `oka artifacts` CLI (`put` / `materialize` / `verify`).
- **Live watcher command lanes (ADR-0038)** and Dart-first lane authoring.
- **Dev-session lanes:** watch-on-save default, asset sync/evict, shader
  bundle reinit in the asset lane (ADR-0037 follow-ups).

### Fixed

- Atomic runner-session publish and torn-read tolerant poll (`oka dev`).
- CLI help points at `https://github.com/arenukvern/oka`.

### Documentation

- Supervisor, artifacts, and OSS onboarding guides; newcomer FAQ; release
  manifest gate in `check-contracts`.

## 0.6.0

### Added

- **Build provenance + verification ladder (ADR-0029).** Every release
  artifact now carries `oka-provenance.json` (engine variant + jar hash,
  AOT snapshot hash + build id, pub-resolution hashes, fingerprints) and is
  validated before packaging: snapshot↔engine pairing, engine variant vs
  build mode, provenance completeness — a wrong pairing is a red build, not
  a device hanging on the splash screen.
- `oka run verify`: the verification ladder as a project-declared target —
  provenance, pairing, install, device health, launch, Dart main (startup
  beacon), first frame, failure signatures — with typed verdicts including
  **inconclusive-device** so unhealthy hosts/devices never produce silent
  evidence. Composable: `VerifyTarget(rungs: [...], extraFailureSignatures:
  [...])`.
- `oka why <step>`: explains a step-cache entry — per-input digests
  recorded at cache time, which inputs changed, and which build-affecting
  sources are not covered by the fingerprint.
- `FlutterBuild.startupProbe`: compiles a generated beacon wrapper so the
  `dart-main` rung can prove `main()` ran without app surgery.
- Failure signatures are data (`launch_failure_signatures.dart`): cause,
  fix, and evidence per needle, shared by `oka run device` and the ladder.

## 0.5.0

### Fixed

- **Android release engine pairing (splash-hang regression):** release APKs
  could package the **debug JIT engine** when the mode-specific
  `flutter.jar` was missing from the Flutter SDK cache — the app booted to
  the splash screen and never ran Dart `main()`. Engine variants are now
  resolved per build mode, `flutter precache --android` runs automatically on
  a cache miss, and a still-missing jar fails the build instead of being
  silently substituted. See
  `docs/evidence/android-release-engine-pairing-2026-09-27.mdx`.

### Changed

- `EngineArtifacts.findFlutterJar` / `extractLibflutter` /
  `extractLibflutterForAbis` take a variant string (`''`, `'-profile'`,
  `'-release'`, via `engineVariantForMode`) instead of a `release` boolean;
  `engineArtifactDirForAbi` is now `engineArtifactDirForVariant`. Profile
  builds use the profile engine directory (previously conflated with
  release).
- `flutter-assemble` / `release-aot` step fingerprints include
  path-dependency Dart sources (pub-workspace layouts resolved from the
  workspace-root `package_config.json`) and `buildArgs` — edits in sibling
  checkouts and R8/assemble argument changes no longer serve stale artifacts.

## 0.4.0

### Added

- `r8_rules` (ADR-0010 `AndroidBuild.r8Rules`): inline, per-app R8/ProGuard
  rules applied after `proguard_files`. oka's default R8 rules are now
  vendor-neutral — dependency-vendor `-dontwarn` lines (Firebase encoders,
  …) are declared per app instead of hardcoded into the platform package.

### Fixed

- `android.proguard_files` now reach R8 (repeated `--pg-conf`); they were
  collected but never passed to the shrinker.

## [0.2.0]

### Added

- Composable cache diagnostics with detailed device, profile, session and
  registry records, `--kind` filtering, and structured observations in JSON.

- Global `oka cache` overview, `clean` preview/apply, bounded project discovery
  with `--scan`, saved cleanup plans, optional terminal confirmation, and a
  machine-readable `schema` with next-action argv arrays.

- `oka cache stats` reports storage by path/platform, including emulator and
  simulator data; `oka cache prune` previews scoped cleanup and applies it only
  with `--apply`. JSON output supports agent workflows.

### Fixed

- Cache size help accepts KB/GB and KiB/GiB suffixes; indexed-store GC handles
  absent stores and measures extracted artifact payloads.

- Use Dart for release and stewardship tooling, without a Python runtime dependency.
- Harden release PR automation against shell interpretation of PR metadata.
- Synchronize and publish the complete seven-package release train, including
  compatible internal dependency constraints.
- Correct contributor setup commands and add enforced real-build CI validation.

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
