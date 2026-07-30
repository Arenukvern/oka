# Changelog

All notable changes to the Oka project will be documented in this file.

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
  - Phase checklist: `docs/PHASE_CHECKLIST.md`
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
