# Oka: Modern Flutter Android Build System

> **Superseded in part (2026-09-06):** the hot reload / dev-mode design now
> lives in [ADR-0010](../decisions/0010-hot-reload-run-loop.md) and
> [docs/guides/hot_reload_plan.md](../guides/hot_reload_plan.md). Phase 4
> below is historical; its 4.4 (incremental native deploy) was **rejected**
> — Android's runtime cannot hot-swap classes in an installed APK — and its
> 4.1 `_flutter.hotRestart` RPC does not exist as written. This document is
> kept for background only.

## Overview

Build a standalone Dart CLI tool that replaces Gradle for Flutter Android builds by directly invoking Android SDK command-line tools, providing 3-5x faster builds, integrated hot reload, and seamless developer experience.

## Architecture

### Core Components

```
oka/
├── lib/
│   ├── src/
│   │   ├── build/              # Android build orchestration
│   │   ├── dev/                # Hot reload & dev mode
│   │   ├── flutter_bridge/     # Flutter SDK integration
│   │   ├── cli/                # Command implementation
│   │   └── config/             # Configuration management
│   └── oka.dart
├── bin/
│   └── oka.dart
└── pubspec.yaml
```

### Configuration File (oka.yaml)

Extends pubspec.yaml with Android-specific configuration including dependencies, signing, build variants, and dev mode settings.

## Implementation Phases

### Phase 1: Core Build Infrastructure

**1.1 Project Setup**

- Create `oka` Dart package with CLI structure
- Setup args parser for commands: `init`, `build`, `dev`, `doctor`, `migrate`
- Implement configuration loader for `oka.yaml`
- Create Android SDK tool locator (aapt2, d8, apksigner, etc.)

**1.2 Basic APK Builder**

Implement `AndroidBuilder` class with methods:

- `compileResources()` - invoke aapt2 compile + link
- `compileJava()` - invoke javac/kotlinc
- `convertToDex()` - invoke d8/r8 for DEX conversion
- `packageApk()` - create APK ZIP structure
- `signApk()` - invoke apksigner
- `buildApk()` - orchestrate full build pipeline

Target: Build simple Flutter app (no plugins) to APK using direct Android SDK tools.

**1.3 Incremental Build System**

- Implement content-based hashing for changed files
- Create `IncrementalCache` to track build artifacts
- Add file watcher for detecting changes
- Skip unchanged build steps

### Phase 2: Dependency Resolution

**2.1 Maven Resolver**

Implement `MavenDependencyResolver`:

- Parse Maven POM XML files
- Resolve transitive dependencies (simple strategy: latest wins)
- Download AARs/JARs from Maven Central via HTTP
- Verify SHA checksums
- Extract and cache in `~/.oka_cache/maven/`

**2.2 AAR Processor**

- Extract AAR contents (classes.jar, res/, AndroidManifest.xml)
- Merge resources from multiple AARs
- Collect native libraries (.so files) by ABI
- Handle R.java generation for AAR resources

**2.3 Dependency Graph**

- Build dependency tree from oka.yaml + plugin dependencies
- Detect and resolve conflicts
- Generate merged dependency list for build

### Phase 3: Plugin Compatibility

**3.1 Plugin Discovery**

- Scan pubspec.yaml for Flutter plugin dependencies
- Locate plugin Android directories
- Read plugin metadata (pubspec.yaml plugin section)

**3.2 Gradle Bridge Parser**

Implement `GradleBridgeParser`:

- Parse plugin's `build.gradle` files
- Extract dependencies declarations
- Identify source directories
- Detect resource directories
- Convert to oka-compatible format

**3.3 Plugin Build Integration**

- Collect plugin Java/Kotlin sources
- Merge plugin resources
- Include plugin dependencies in build
- Handle plugin AndroidManifest.xml merging

**3.4 Plugin Migration Tool**

Create `oka migrate` command:

- Analyze existing Gradle setup
- Generate oka.yaml from build.gradle
- Identify plugins needing manual configuration
- Output migration report

### Phase 4: Hot Reload & Development Mode

**4.1 VM Service Integration**

Implement `HotReloadManager`:

- Connect to Flutter VM Service via DDS
- Discover main isolate
- Implement hot reload via `ext.flutter.reassemble`
- Implement hot restart via `_flutter.hotRestart`
  *(historical note: no such RPC exists — hot restart is a full
  non-incremental kernel compile plus app restart, handled by flutter_tools'
  run/attach session; see ADR-0010)*

**4.2 File Watcher**

- Watch lib/\*_/_.dart for Dart changes
- Watch android/ for native changes
- Watch resources for asset changes
- Debounce rapid changes

**4.3 Change Detection & Dispatch**

Create `ChangeDetector`:

- Classify changes: Dart (hot reload), native (incremental rebuild), manifest (full rebuild)
- Route to appropriate handler
- Show clear progress indicators

**4.4 Incremental Native Deploy**

> **REJECTED (ADR-0010 §5).** Android's runtime cannot hot-swap classes in an
> installed APK; there is no supported path to push incremental DEX into a
> running app. Native, resource, and manifest changes always route to a full
> rebuild + reinstall. Kept for the historical record only.

For native code changes:

- Compile only changed Java/Kotlin files
- Generate incremental DEX
- Push via ADB to device app directory
- Trigger hot restart (not cold reinstall)

**4.5 Dev Mode Server**

Implement `oka dev` command:

- Build and install debug APK
- Launch app on device
- Connect to VM Service
- Start file watchers
- Handle keyboard commands (r, R, q, p, d, etc.)
- Display real-time feedback

### Phase 5: Build Variants & Advanced Features

**5.1 Build Configurations**

- Support debug/release/profile modes
- Implement ProGuard/R8 rules merging
- Code shrinking and obfuscation for release
- Multiple flavor support (dev, prod, staging)

**5.2 Signing**

- Debug keystore auto-generation
- Release signing from oka.yaml config
- Environment variable support for CI/CD
- Keystore validation

**5.3 AAB Support**

- Implement `bundletool` integration
- Create Android App Bundle structure
- Split APKs by ABI/density/language
- Sign bundle

**5.4 Native Library Handling**

- Support multiple ABIs (arm64-v8a, armeabi-v7a, x86_64)
- Extract .so files from dependencies
- Package in correct APK structure
- Strip symbols for release builds

### Phase 6: CLI & Developer Experience

**6.1 Command Implementation**

`oka init`

- Detect Flutter project
- Generate oka.yaml from pubspec.yaml
- Scan plugins and dependencies
- Create default signing config

`oka build apk/aab`

- Full build with progress indicators
- Support --release, --debug, --profile flags
- Support --flavor flag
- Output size analysis

`oka dev`

- Interactive development mode
- Hot reload/restart support
- Device auto-detection or selection
- Keyboard shortcuts

`oka doctor`

- Check Flutter SDK
- Check Android SDK and tools
- Check Java/Kotlin versions
- Verify oka.yaml configuration

`oka clean`

- Clear build cache
- Option for full cache clear (--full)

`oka analyze`

- APK/AAB size breakdown
- Dependency tree visualization
- Build performance metrics

**6.2 Device Management**

- ADB integration for device discovery
- Install APK to device
- Launch app and capture logcat
- Forward ports for VM Service

**6.3 Error Handling & Diagnostics**

- Clear error messages with suggestions
- Verbose mode showing exact tool commands
- Build failure troubleshooting hints
- Link to documentation for common issues

### Phase 7: Testing & Documentation

**7.1 Integration Tests**

- Test building sample Flutter apps
- Test plugin compatibility with popular plugins
- Test hot reload/restart workflows
- Test on multiple Android versions
- CI/CD integration tests

**7.2 Documentation**

- README with quick start
- Architecture documentation
- Migration guide from Gradle
- Plugin author guide
- Troubleshooting guide
- API documentation

**7.3 Example Projects**

- Simple app (no plugins)
- App with popular plugins
- Plugin development example
- CI/CD configuration examples

## Technical Implementation Notes

### Key Android SDK Tools

- **aapt2**: Resource compilation (`compile`, `link`)
- **javac/kotlinc**: Java/Kotlin compilation
- **d8**: DEX conversion (debug)
- **r8**: DEX conversion with optimization (release)
- **zipalign**: APK optimization
- **apksigner**: APK signing
- **bundletool**: AAB creation
- **adb**: Device communication

### Performance Optimizations

- Parallel downloads for dependencies
- Parallel compilation where possible
- Aggressive caching with content hashing
- Skip unchanged build steps
- No JVM startup overhead

### Flutter SDK Integration

Leverage existing Flutter tools:

- Use `flutter doctor` for SDK validation
- Use Flutter engine binaries
- Integrate with Flutter's asset bundling
- Connect to Flutter's VM Service

### Plugin Compatibility Strategy

1. Auto-convert simple Gradle configs
2. Provide manual override in oka.yaml
3. Support legacy Gradle execution for complex plugins (isolated)
4. Document common migration patterns
5. Provide migration tool for plugin authors

## Success Metrics

- Build time: 3-5x faster than Gradle for incremental builds
- Hot reload: <200ms for Dart changes
- Native incremental: <2s for small native changes
- Size: <10MB tool distribution
- Compatibility: 90%+ of popular Flutter plugins work without modification

## Migration Path

1. Start with new projects (oka init)
2. Provide migration tool for existing projects
3. Maintain both systems initially
4. Gradual plugin ecosystem migration
5. Community feedback and iteration
