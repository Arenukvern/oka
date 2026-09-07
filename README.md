# Oka — declarative, AI-native builds for Flutter. Starting with no-Gradle Android.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-docs.page-02569B)](https://docs.page/arenukvern/oka)
[![CI](https://github.com/Arenukvern/oka/actions/workflows/ci.yml/badge.svg)](.github/workflows/ci.yml)

Oka's north star: **one code for every platform build.** Today, building an
app means negotiating with a pile of locked, untyped, scattered configs —
Gradle DSL, manifests, properties, signing files — that repeat across every
project, drift apart, and cannot be unified or copied. Oka replaces that with
a **declarative, compositional pipeline written in ordinary Dart**: typed,
refactorable, and copyable between projects. Starting with **Android** — no
Gradle at all — and built to extend to any platform
([the long game](#the-long-game)).

## Why oka was created

Not because Gradle is slow. Because **it is locked and unmanageable** — and
the same is true of every platform's build system:

- Your app is one codebase, but building it means touching a dozen scattered
  configs in different languages — `build.gradle.kts`, XML manifests,
  `local.properties`, proguard rules, signing properties, plists. None are
  typed, none share structure, none can be checked as a whole.
- Every project re-solves the same problems: package name, versions, icons,
  permissions, deeplinks, dependency quirks. The configs **repeat and drift**,
  and unifying them across projects is impossible — they don't even share a
  format.
- You don't operate the build; you _negotiate_ with it. The toolchain is
  locked behind plugin DSLs and hidden defaults, and when it breaks, the fix
  lives somewhere you can't read or control.

Oka's answer: collapse all of it into **one code** — a typed, composable
pipeline in Dart that you own end to end:

- **Declarative** — the build is typed values (`AndroidBuild`,
  `PipelineOverrides`, `ManifestSpec`) composed in a Dart entrypoint. No
  config DSL sprawl; the config is code, so it's checkable, diffable, and
  **copyable between projects** — the same `oka_pipeline.dart` works
  everywhere oka does.
- **Compositional** — every capability is a `BuildStep`, a typed value, or a
  resolver service. Pipelines are immutable values; a new platform is a new
  package implementing the same contract. You can build any pipeline.
- **AI-native** — self-describing plans (`oka explain`), machine-checkable
  gates (`oka compare`), single-step probes (`oka debug step`), deterministic
  byte-reproducible artifacts, and failures that name the fix. The goal: _an
  agent can set up and fix a platform build from oka's messages alone._

Speed is a consequence, not the pitch: with the build as one readable code
path and no Gradle, incremental builds drop to ~23s — but the reason oka
exists is that **the config should be one simple, manageable, copyable
thing.** Future generations of oka keep pushing everything that is still
per-platform noise into that single Dart surface.

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
- 🔁 **Dev loop** — `oka dev` (build-parity check → install → launch →
  attach session: hot reload / hot restart) with agent streams (`--json`,
  `--watch`), [ADR-0011](docs/decisions/0011-hot-reload-run-loop.md)

Not yet (by design, see [the long game](#the-long-game)): iOS, desktop, web.

## Installation

```bash
dart pub global activate oka        # pub.dev
# or from source:
git clone https://github.com/Arenukvern/oka.git && cd oka
just install && just global

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

```
| Command | What an agent gets |
|---|---|
| `oka explain` / `oka build --dry-run` | The validated plan: steps, artifact chain, signing, versions — zero tools invoked |
| `oka explain --deps` | The resolved dependency plan (cache-first; `--network` gates with exit 1) |
| `oka debug step <name>` | One pipeline step re-run against `.oka_cache` — 10-minute loops become 30-second probes |
| `oka compare a.apk b.apk` | Byte-equivalence gate (badging + zip entries) — refactors prove, not claim |
| `oka doctor` | Full environment + build-health audit |
| `oka dev` | build-parity check → install → launch → attach session: hot reload / hot restart; `--json` events on stdout, control lines on stdin, `--watch` loop |
```

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

```
| Package | Pub | Purpose |
|---|---|---|
| [`oka`](https://pub.dev/packages/oka) | CLI + agent surface (this repo) |
| [`oka_core`](https://pub.dev/packages/oka_core) | Platform-agnostic contracts: pipeline, artifacts, composition root, typed config |
| [`oka_android`](https://pub.dev/packages/oka_android) | Android pipelines, toolchain, plugin packaging |
```

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

```
| I want to… | Read |
|---|---|
| Run/build/test | [Build & configuration guide](https://docs.page/arenukvern/oka/guides/build_and_config) |
| Understand boundaries & the north star | [Why this repo matters](https://docs.page/arenukvern/oka/start_here/why_this_repo_matters) |
| Know why it's designed this way | [Design FAQ](https://docs.page/arenukvern/oka/guides/design_faq) |
| Check phase status | [`docs/PHASE_CHECKLIST.md`](docs/PHASE_CHECKLIST.md) |
```

## Contributing

Contributions welcome! See the
[contribution guide](https://docs.page/arenukvern/oka/contributing/contribution_guide).
Releases are automated via release-please — use conventional commits
(`feat:`, `fix:`, `docs:`); run `just check-contracts` before merging.
Agents: start from [`AGENTS.md`](AGENTS.md).

## Security

See [`SECURITY.md`](SECURITY.md). Please report vulnerabilities privately.

## License

MIT — see [LICENSE](LICENSE).
