# Changelog

<!-- markdownlint-disable MD052 -->

All notable changes to the Oka project will be documented in this file.

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
