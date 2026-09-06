# Oka — declarative, AI-native builds for Flutter. Starting with no-Gradle Android.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-docs.page-02569B)](https://docs.page/arenukvern/oka)
[![CI](https://github.com/Arenukvern/oka/actions/workflows/ci.yml/badge.svg)](.github/workflows/ci.yml)

Oka's north star: **platform builds as declarative, composable, typed pipelines
that both humans and AI agents can run, inspect, and fix — easy to set up for
any platform.** Today that promise is kept for **Android**: a no-Gradle
pipeline (`flutter assemble` + direct SDK tools) that builds APKs and App
Bundles without a Gradle daemon, AGP, or 30s+ configuration tax. Other
platforms follow the same composition model — see
[the long game](#the-long-game).

## Why

Every Flutter Android build pays a Gradle tax: daemon startup, configuration
phase, plugin resolution — before any of your code compiles. For AI-assisted
workflows, where builds run constantly and an agent iterates against error
output, that tax — plus Gradle's non-determinism and opaque errors — dominates.

Oka's answer is a build system designed for the agent loop from first
principles:

- **Declarative** — the build is typed values (`AndroidBuild`,
  `PipelineOverrides`, `ManifestSpec`), composed in a Dart entrypoint. No
  YAML sprawl, no stringly flags; config is code that agents write well.
- **Compositional** — every capability is a `BuildStep`, a typed value, or a
  resolver service. Pipelines are immutable values; a new platform is a new
  package implementing the same contract.
- **AI-native** — self-describing plans (`oka explain`), machine-checkable
  gates (`oka compare`), single-step probes (`oka debug step`), deterministic
  byte-reproducible artifacts, and failures that name the fix. The goal: *an
  agent can set up and fix a platform build from oka's messages alone.*

## Status: Android first

Production-validated on real apps (18-plugin production app; incremental
builds ~23s; bundletool-validated release AABs).

- 🚀 **No Gradle, ever** — the default path never falls back to
  `flutter build apk` (enforced by tests)
- 📦 **Plugin packaging** — Java/Kotlin sources, Maven/AAR deps (natives +
  res), real `GeneratedPluginRegistrant`, transitive POM/BOM resolution
- 🧩 **AAB** — hand-assembled bundles, optional bundletool verification
- 🔧 **Self-resolving** — missing tools self-install, java levels auto-bump,
  versions fall back to pubspec, dev-only plugins auto-exclude
- ✅ **Post-build gates** — lint (version, signing, size budget), byte
  equivalence via `oka compare`
- 🔁 **Dev loop** — `oka dev` (install → launch → hot reload/restart, agent
  streams) — in progress, [ADR-0011](docs/decisions/0011-hot-reload-run-loop.md)

Not yet (by design, see [the long game](#the-long-game)): iOS, desktop, web.

## Installation

```bash
dart pub global activate oka        # pub.dev
# or from source:
git clone https://github.com/Arenukvern/oka.git && cd oka
make install && make global

# one-time SDK bootstrap (or point at an existing Android SDK)
oka get android-sdk
oka doctor              # verify everything
```

Requirements: Flutter SDK, JDK 11+; Android build-tools + platforms are
bootstrapped into `~/.oka/android-sdk` by `oka get android-sdk`. No Gradle.

## Quick start

```bash
cd your-flutter-project
oka init                # full-Dart config: scaffolds tool/oka_pipeline.dart
oka build apk           # → .oka_cache/build/debug/app-debug.apk

adb install -r .oka_cache/build/debug/app-debug.apk
adb shell am start -n <package>/.MainActivity
```

Store / release:

```bash
oka build apk --release
oka build aab --verify-aab      # bundle + bundletool universal-APK check
oka explain --deps --network    # resolve the full dependency plan pre-build
```

Existing project on `oka.yaml`? `oka init --from-yaml` converts it 1:1 into
the typed Dart entrypoint.

## The agent surface

Every operation is checkable and scriptable — this is what "AI-native" means
here, not a chat wrapper:

| Command | What an agent gets |
|---|---|
| `oka explain` / `oka build --dry-run` | The validated plan: steps, artifact chain, signing, versions — zero tools invoked |
| `oka explain --deps` | The resolved dependency plan (cache-first; `--network` gates with exit 1) |
| `oka debug step <name>` | One pipeline step re-run against `.oka_cache` — 10-minute loops become 30-second probes |
| `oka compare a.apk b.apk` | Byte-equivalence gate (badging + zip entries) — refactors prove, not claim |
| `oka doctor` | Full environment + build-health audit |
| `oka dev` *(in progress)* | install → launch → hot reload/restart with structured `--json` events |

## Configuration

Config is a typed Dart entrypoint — programmable, refactorable, agent-writable:

```dart
// tool/oka_pipeline.dart
Future<void> main(List<String> args) => okaRun(
  args,
  oka: const Oka(
    pipelines: [
      AndroidPipeline(
        config: AndroidBuild(
          name: 'my_app',
          packageName: 'com.example.my_app',
          minSdk: '23', targetSdk: '36', compileSdk: '36',
          versionCode: 51, versionName: '1.0.0',
          javaVersion: 17,
        ),
        overrides: PipelineOverrides(
          resourceConfigs: ['en', 'ru'],
          manifest: ManifestSpec(permissions: [/* … */]),
          deeplinks: [DeeplinkConfig(scheme: 'https', host: 'my.app')],
        ),
        steps: [...AndroidPipeline.defaultSteps],
      ),
    ],
  ),
);
```

Prefer YAML? `oka.yaml` fast-settings remain fully supported
(`oka init --yaml`); `oka init --from-yaml` migrates. Precedence:
defaults < `oka.yaml` < Dart config < CLI args.

Full reference: [build & configuration guide](https://docs.page/arenukvern/oka/guides/build_and_config).

## How it works

1. Host checks + codegen (manifest, `MainActivity`, adaptive vector icons)
2. `flutter assemble` (assets / kernel / AOT) — never `flutter build apk`
3. Engine `libflutter.so` extraction from the Flutter cache
4. Plugin packaging + Maven/AAR resolution (parallel, deterministic)
5. `aapt2` → `javac`/`kotlinc` → `d8` compile-and-dex (sorted, reproducible)
6. Extra assets, zip staging, `zipalign -p 4`, `apksigner`
7. Layout validation + post-build lint

Every step is a `BuildStep` with declared `requires`/`provides` typed
artifacts; the whole chain is validated **before any tool runs**. Custom
pipelines: [example/tool/oka_pipeline.dart](example/tool/oka_pipeline.dart).

## Packages

| Package | Pub | Purpose |
|---|---|---|
| [`oka`](https://pub.dev/packages/oka) | CLI + agent surface (this repo) |
| [`oka_core`](https://pub.dev/packages/oka_core) | Platform-agnostic contracts: pipeline, artifacts, composition root, typed config |
| [`oka_android`](https://pub.dev/packages/oka_android) | Android pipelines, toolchain, plugin packaging |

## The long game

One platform proves the model; the model is built for many. The architecture
is already split for it: `oka_core` is platform-agnostic, and a platform is
just another `PlatformPipeline` selected by `oka --platform`. Expansion is
deliberately **criteria-gated**, not calendar-driven:

1. **Depth before breadth.** Android ships the full agent loop
   (`oka dev`, ADR-0011) before a second platform starts — the loop is the
   product.
2. **Abstraction hygiene.** No platform detail leaks into `oka_core`; any
   capability that can't be expressed as `PlatformPipeline`/`BuildStep`/typed
   value is a design smell to fix first.
3. **Second platform = iOS** (the strongest candidate: full CLI toolchain,
   highest Flutter demand, signing/provisioning is exactly what agents need
   help with) — gated on an ADR proving the pipeline model maps
   (assemble → compile → codesign → validate). Desktop (MSIX et al.) is the
   cheap third; web needs nothing oka-shaped.

Full charter: [why oka matters](https://docs.page/arenukvern/oka/start_here/why_this_repo_matters).

## Limitations

- ❌ Full Gradle/AGP compatibility (AIDL, RenderScript, data binding, NDK)
- ❌ Some plugins with complex native Android code
- ❌ Hot reload during development (in progress — ADR-0011)
- ❌ iOS/desktop/web targets (criteria-gated, see [the long game](#the-long-game))

Run `oka doctor` to verify your environment.

## Documentation

Published via docs.page: **[docs.page/arenukvern/oka](https://docs.page/arenukvern/oka)**

| I want to… | Read |
|---|---|
| Run/build/test | [Build & configuration guide](https://docs.page/arenukvern/oka/guides/build_and_config) |
| Understand boundaries & the north star | [Why this repo matters](https://docs.page/arenukvern/oka/start_here/why_this_repo_matters) |
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
