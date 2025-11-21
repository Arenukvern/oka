# Oka: AI-Powered Flutter Android Build System

Oka is a modern build system that replaces Gradle for Flutter Android builds, providing **3-5x faster builds** with integrated hot reload and AI-assisted configuration.

## Features

- 🚀 **3-5x Faster Builds** - Direct Android SDK tool invocation, no Gradle overhead
- 🤖 **AI-Assisted Configuration** - Automatic Gradle-to-oka.yaml conversion
- ⚡ **Hot Reload Integration** - <200ms Dart hot reload, incremental native builds
- 📦 **Simple Configuration** - YAML-based, pub-style dependency resolution
- 🎯 **Zero Runtime Overhead** - Extension type models for type safety
- 🔧 **Developer Friendly** - Clear errors, verbose mode, integrated doctor command

## Quick Start

### Installation

```bash
# Clone repository
git clone https://github.com/yourusername/oka.git
cd oka

# Install dependencies
dart pub get

# Activate globally
dart pub global activate --source path .
```

### Setup

1. **Check system requirements:**

```bash
oka doctor
```

2. **Set up Gemini API key** (for AI-assisted Gradle conversion):

```bash
export GEMINI_API_KEY="your-api-key"
# Get your key from: https://makersuite.google.com/app/apikey
```

### Usage

**Initialize a Flutter project:**

```bash
cd your-flutter-project
oka init
```

**Build APK or AAB:**

```bash
# Traditional Android SDK build (default)
oka build apk

# Flutter hybrid build (cargo-apk + Flutter tools)
oka build apk --flutter
oka build aab --flutter

# Release builds
oka build apk --release
oka build apk --flutter --release
oka build aab --flutter --release

# Debug builds
oka build apk --flutter --debug

# With verbose output
oka build apk --flutter --verbose
```

**Development mode** (coming soon):

```bash
oka dev
```

**Clean cache:**

```bash
# Clean build cache
oka clean

# Clean everything including dependencies
oka clean --full

# Clean AI conversion cache
oka clean --ai-cache
```

## Flutter Hybrid Builds

Oka supports two build approaches:

### Traditional Android SDK Build (Default)

- Direct Android SDK tool invocation
- Manual resource compilation, Java/Kotlin compilation, DEX conversion
- No Gradle dependency
- Best for pure Android apps or custom Android plugins

### Flutter Hybrid Build (`--flutter` flag)

- Combines Flutter tools + cargo-apk + Rust NativeActivity
- Flutter handles Dart compilation and asset bundling
- Rust NativeActivity provides Android integration and hosts Flutter engine
- cargo-apk handles APK/AAB packaging and signing
- Best for Flutter apps wanting faster builds than Gradle

**When to use Flutter hybrid builds:**

- You're building a Flutter app
- You want Flutter's asset management and plugin system
- You want faster builds than Gradle but keep Flutter compatibility
- You need Android App Bundle (AAB) support

**Requirements for Flutter builds:**

- Flutter SDK installed
- cargo-apk installed (`cargo install cargo-apk`)
- Rust toolchain
- Android SDK (for cargo-apk packaging)

**Environment Setup:**

Before building, ensure Android SDK is available:

```bash
# Set Android SDK path (choose one)
export ANDROID_SDK_ROOT=/path/to/android/sdk
# or
export ANDROID_HOME=/path/to/android/sdk

# Common locations:
# macOS: ~/Library/Android/sdk
# Linux: ~/Android/Sdk
# Windows: %LOCALAPPDATA%\Android\Sdk
```

**Supported output formats:**

- APK (Android Package): `oka build apk --flutter`
- AAB (Android App Bundle): `oka build aab --flutter`

## Configuration

Oka uses `oka.yaml` for configuration:

```yaml
name: my_app
version: 1.0.0

flutter:
  entrypoint: lib/main.dart
  assets:
    - assets/
  build_mode: debug
  target_platform: android-arm64
  tree_shake_icons: true
  enable_hot_reload: true
  build_args: []

android:
  compile_sdk: "34"
  min_sdk: "21"
  target_sdk: "34"
  package_name: com.example.myapp
  version_code: 1
  version_name: 1.0.0
  source_dirs:
    - src/main/java
    - src/main/kotlin
  res_dirs:
    - src/main/res
  abis:
    - arm64-v8a
    - armeabi-v7a

# Cargo-apk specific configuration for Flutter hybrid builds
cargo_apk:
  build_targets: ["arm64-v8a", "armeabi-v7a", "x86", "x86_64"]
  application:
    label: "My App"
    icon: "@mipmap/ic_launcher"
    theme: "@style/AppTheme"
    debuggable: false
    extract_native_libs: true
  activity:
    label: "My App"
    launch_mode: "singleTop"
    orientation: "portrait"
    exported: true
    config_changes: ["orientation", "keyboardHidden", "screenSize"]
  permissions:
    - "android.permission.INTERNET"
    - "android.permission.ACCESS_NETWORK_STATE"
  features: []
  manifest_entries: {}

dependencies:
  - name: androidx.core:core-ktx
    version: 1.10.0
    source: maven
  - name: androidx.appcompat:appcompat
    version: 1.6.1
    source: maven
```

## Architecture

### Extension Type Models

All data models use Dart extension types for zero runtime overhead:

```dart
extension type const OkaConfig(Map<String, dynamic> value) {
  factory OkaConfig.fromJson(dynamic json) => OkaConfig(jsonDecodeMap(json));

  AndroidConfig get android => AndroidConfig.fromJson(value['android']);
  List<Dependency> get dependencies => /* ... */;

  Map<String, dynamic> toJson() => value;
}
```

### AI-Assisted Conversion

Oka uses AI (Apple Foundation Models on macOS, Gemini fallback) to convert Gradle configurations:

1. Reads `build.gradle` as text (no parsing)
2. Sends to AI with structured prompts
3. AI extracts dependencies, SDK versions, configuration
4. Converts to oka.yaml format
5. Caches conversion for offline use

### Build Pipeline

1. **Resource Compilation** - `aapt2 compile` and `link`
2. **Source Compilation** - `kotlinc` and `javac`
3. **DEX Conversion** - `d8` (debug) or `r8` (release with optimization)
4. **APK Packaging** - ZIP structure with resources and DEX
5. **Signing** - `apksigner` with debug or release keystore
6. **Zipalign** - APK optimization

## Requirements

- **Flutter SDK** - Latest stable version
- **Android SDK** - With build-tools, platform-tools
- **JDK** - Version 11 or later
- **Kotlin** - Optional (will be downloaded if needed)
- **Gemini API Key** - For AI-assisted Gradle conversion

Run `oka doctor` to verify all requirements.

## Performance Targets

- **Initial build:** Match or beat Gradle
- **Incremental build:** 3-5x faster than Gradle
- **Hot reload:** <200ms for Dart changes
- **Native rebuild:** <5s (vs 30s+ with Gradle)

## Limitations

Current version does not support:

- ❌ build_runner / code generation (use Flutter tools separately)
- ❌ Complex Android features (AIDL, RenderScript, data binding)
- ❌ NDK/native C++ compilation (except via cargo-apk)
- ❌ 100% Gradle compatibility - targets common Flutter use cases
- ❌ Flutter plugins with complex Android native code
- ❌ Hot reload during development (planned for future)

## Example Apps

See `example_app/` for a test app with:

- In-app purchases (monetization)
- Firebase Crashlytics integration
- Basic UI to validate real-world plugin compatibility

## Contributing

Contributions welcome! This is an experimental project exploring:

- AI-assisted build configuration
- Direct Android SDK tool usage
- Modern Dart patterns (extension types)
- Flutter build system alternatives

## License

MIT License - see LICENSE file for details

## Roadmap

- [x] Android App Bundle (AAB) support via cargo-apk
- [x] Cargo-apk integration with Flutter
- [x] Rust NativeActivity implementation
- [ ] Complete hot reload integration
- [ ] AAR dependency processing
- [ ] Plugin system for custom build steps
- [ ] Support for popular Flutter plugins
- [ ] Build cache sharing across machines
- [ ] CI/CD integration examples
- [ ] Dart 3.10 build hooks integration

## Acknowledgments

- Inspired by the need for faster Flutter Android builds
- Uses Apple Foundation Models and Google Gemini for AI assistance
- Built with modern Dart features (extension types, from_json_to_json)
