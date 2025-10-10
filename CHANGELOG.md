# Changelog

All notable changes to the Oka project will be documented in this file.

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
