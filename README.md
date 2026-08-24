# Oka: no-Gradle Flutter Android builds

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-docs.page-02569B)](https://docs.page/arenukvern/oka)

Oka is a Dart CLI that replaces Gradle for Flutter Android builds. It runs
`flutter assemble` and invokes Android SDK tools directly (`aapt2`, `javac`,
`d8`, `zipalign`, `apksigner`) — no Gradle daemon, no AGP, no 30s+
configuration overhead per build.

## Features

- 🚀 **No Gradle, ever** — the default path never falls back to
  `flutter build apk` (enforced by tests)
- 📦 **Plugin packaging** — plugin Java/Kotlin sources, Maven/AAR deps
  (natives + res included), real `GeneratedPluginRegistrant`
- ⚡ **Fast settings** — extra deps, extra assets, deeplinks, adaptive vector
  launcher icons via `oka.yaml`
- 🧩 **AAB support** — hand-assembled App Bundles, optional bundletool
  verification
- 🔁 **Dependency recovery** — runtime missing-class crashes map back to
  Maven artifacts automatically
- 🤖 **AI-assisted migration** — convert existing `build.gradle` to
  `oka.yaml`

## Installation

```bash
dart pub global activate oka        # pub.dev (after first publish)
# or from source:
git clone https://github.com/Arenukvern/oka.git && cd oka
make install && make global

# one-time SDK bootstrap (or point at an existing Android SDK)
oka get android-sdk
oka doctor              # verify everything
```

For AI agents, install the bundled skill:

```bash
npx skills add Arenukvern/oka --skill oka-maintenance
```

Requirements: Flutter SDK, JDK 11+, Android build-tools + platforms
(`oka get android-sdk` bootstraps these into `~/.oka/android-sdk`; no Gradle
needed).

## Quick start

```bash
cd your-flutter-project
oka init                # create oka.yaml (AI-assisted from Gradle if present)
oka build apk           # → .oka_cache/build/debug/app-debug.apk

adb install -r .oka_cache/build/debug/app-debug.apk
adb shell am start -n <package>/.MainActivity
```

Release & store:

```bash
oka build apk --release
oka build aab --verify-aab      # bundle + bundletool universal-APK check
```

More copy-paste recipes: [quick recipes](https://docs.page/arenukvern/oka/start_here/quick_recipes).

## Configuration highlights

Oka reads `oka.yaml`. The most-used fast settings:

```yaml
pipeline:
  extra_deps:                       # runtime Maven deps without editing oka
    - "com.squareup.okhttp3:okhttp:4.12.0"
  extra_assets:                     # merge files/dirs into flutter_assets
    - from: build/generated.json
      to: generated.json
  local_aars:                       # local .aar files (classes, natives, res)
    - libs/my-native-lib.aar
  deeplinks:                        # autoVerify intent-filters
    - scheme: https
      host: oka.example.com
      pathPrefix: /app

android:
  icon:                             # adaptive vector launcher icon (API 26+)
    background_color: "#E8F5E9"
    vector: assets/icon/foreground.xml
```

Missing a class at runtime? Oka suggests the artifact on build failure, or
run `oka get dep group:artifact:version`.

Full reference: [build & configuration guide](https://docs.page/arenukvern/oka/guides/build_and_config).

## How it works

The default pipeline (composable — ADR 0002) runs:

1. Host checks + codegen (manifest, `MainActivity`, icons)
2. `flutter assemble` (assets / kernel / AOT) — never `flutter build apk`
3. Engine `libflutter.so` extraction from the Flutter cache
4. Plugin packaging + Maven/AAR dependency resolution
5. `aapt2` → `javac` → `d8` compile-and-dex
6. Extra assets merge, zip staging, `zipalign -p 4`, `apksigner`
7. Layout validation of the produced APK/AAB

Every step is a `BuildStep`; reorder or replace them from Dart
([example/bin/custom_pipeline.dart](example/bin/custom_pipeline.dart)).

Design rationale: [design FAQ](https://docs.page/arenukvern/oka/guides/design_faq) ·
decisions: [`docs/decisions/`](docs/decisions/index.md).

## Limitations

- ❌ Full Gradle compatibility (AIDL, RenderScript, data binding, NDK)
- ❌ Some plugins with complex native Android code
- ❌ Hot reload during development (planned)
- ❌ iOS/desktop/web targets

Run `oka doctor` to verify your environment.

## Documentation

Published via docs.page: **[docs.page/arenukvern/oka](https://docs.page/arenukvern/oka)**

| I want to… | Read |
|---|---|
| Run/build/test | [Build & configuration guide](https://docs.page/arenukvern/oka/guides/build_and_config) |
| Understand boundaries | [Why this repo matters](https://docs.page/arenukvern/oka/start_here/why_this_repo_matters) |
| Know why it's designed this way | [Design FAQ](https://docs.page/arenukvern/oka/guides/design_faq) |
| Check phase status | [`docs/PHASE_CHECKLIST.md`](docs/PHASE_CHECKLIST.md) |

## Contributing

Contributions welcome! See the
[contribution guide](https://docs.page/arenukvern/oka/contributing/contribution_guide).
Releases are automated via release-please — use conventional commits
(`feat:`, `fix:`, `docs:`); run `make check-contracts` before merging.
Agents: start from [`AGENTS.md`](AGENTS.md).

## Security

See [`SECURITY.md`](SECURITY.md). Please report vulnerabilities privately.

## License

MIT — see [LICENSE](LICENSE).
