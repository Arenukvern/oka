# Oka — one code for every platform build

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-docs.page-02569B)](https://docs.page/arenukvern/oka)
[![CI](https://github.com/Arenukvern/oka/actions/workflows/ci.yml)](https://github.com/Arenukvern/oka/actions/workflows/ci.yml)

**Oka is a declarative, compositional, AI-native build system.** Platform
build configs are locked, scattered, and endlessly repeated — gradle DSL,
XML manifests, plists, per-store `index.html` surgery. Oka collapses them
into one typed, copyable Dart surface that both humans and agents run,
inspect, and fix. The promise is kept **deepest for Android** — a no-Gradle
pipeline (`flutter assemble` + direct Android SDK tools: no daemon, no AGP) — and extends to
**web distribution** (the shell station: per-store `web/index.html` as
typed, drift-checked Dart + deploy targets). Three words carry the design:

- **Declarative** — the build is typed values (`AndroidBuild`,
  `ManifestSpec`, `WebShellSpec`, …) composed in a project-owned Dart
  entrypoint. Config is code: checkable, diffable, copyable between projects.
- **Compositional** — every capability is a `BuildStep` or typed value; the
  whole chain is validated before any tool runs. A store target, a platform,
  or a deploy flow is another package over the same kernel.
- **AI-native** — self-describing plans (`oka explain`), single-step probes,
  byte-equivalence gates, and failures that name the fix. _An agent can set
  up and fix a platform build from oka's messages alone._

Production-validated on real apps (18-plugin production app;
bundletool-validated release AABs).

## Quickstart: first build in under two minutes

Install once — either the one-liner (installs via `dart pub global
activate`; requires Dart, not Flutter):

```bash
curl -fsSL https://raw.githubusercontent.com/Arenukvern/oka/main/install.sh | bash
```

or directly:

```bash
dart pub global activate oka
oka get android-sdk     # one-time SDK bootstrap into ~/.oka/android-sdk
oka doctor              # verify everything
```

**Build.** In your Flutter project, `oka init` scaffolds the config as a
typed Dart entrypoint (`tool/oka_pipeline.dart`) — or converts an existing
`oka.yaml` 1:1 with `oka init --from-yaml`. Then build release, no Gradle:

```bash
oka init
oka build apk --release   # → .oka_cache/build/release/app-release.apk
```

**Run on a device.** One command installs the newest built APK, launches it,
and scans the device log for failure signatures (`oka launch` = same
dispatch):

```bash
oka run device
```

**Dev loop.** Hot reload / hot restart against an oka-built APK — parity
check → install → launch → attach session. Humans get `r` / `R` / `q` / `d`;
agents get `--json` events on stdout and control lines on stdin, or the
hands-free `--watch` loop:

```bash
oka dev                 # TTY session: r hot reload · R hot restart · q quit · d detach
oka dev --watch --json  # agent loop: Dart edits auto-reload; native edits
                        # print the honest full-rebuild command
```

Hot reload is Dart-only — native/res/manifest changes always need
`oka build apk --debug` + reinstall ([ADR-0011](docs/decisions/0011-hot-reload-run-loop.md)).

Existing project on `oka.yaml`? `oka init --from-yaml` converts it 1:1.
Migrating from Gradle: the [migration guide](https://docs.page/arenukvern/oka/guides/gradle_migration).

## Publishing: targets are project-declared

Play and AppGallery builds are **one Android app, composed differently** —
not new CLIs, not new platforms ([ADR-0014](docs/decisions/0014-distribution-targets-secrets-model.md)).
Declare publish targets in `tool/oka_pipeline.dart` and run them with
`oka run <target>`. Both are **dry-run by default**: the plan names the
endpoint, track, artifact, and metadata before anything ships, and
succeeds without credentials. Real, from the [example app](example/tool/oka_pipeline.dart):

```dart
targets: const [
  DeviceTarget(),
  // Dry-run by default: `oka run publish-play` prints the plan, zero HTTP.
  // Real run: `dryRun: false` + a service-account JSON referenced BY PATH
  // (tier-2 credential — never a dart-define, never a value).
  PlayPublishTarget(),
  // GMS-excluded variant + AppGallery Connect tail: `oka run publish-huawei`.
  HuaweiPublishTarget(
    release: HuaweiReleaseConfig(appId: '110012345'),
  ),
),
```

```bash
oka build aab --release --verify-aab
oka run publish-play       # oka run publish-huawei
```

Secrets follow the ADR-0014 tier rule: dart-defines carry app-visible
non-secrets; credentials are **paths** resolved via typed config →
`OKA_<TARGET>_*` env var → `~/.oka/credentials/<target>/`. Full console
setup, file formats, and failure playbook: the
[publishing guide](https://docs.page/arenukvern/oka/guides/publishing).

## Web: the shell station, not a platform

Web apps get the same treatment at the configuration-and-distribution
layer — where the real pain lives (per-store `index.html` surgery,
branch-per-store drift). `oka_web` composes the shell (SDK scripts with
declarative ordering phases, preconnects, PWA manifest, icons) as typed,
const, **drift-checked** Dart; store packages ship contributions; deploy
targets push to GitHub Pages and itch.io — dry-run by default. The
compile stays an honest, named delegation to `flutter build web`
([ADR-0016](docs/decisions/0016-web-shell-station-store-contributions.md)):

```dart
targets: const [
  WebShellTarget(spec: mySpec, contributions: [MyStoreContribution()]),
  WebBuildTarget(),                       // delegates to flutter build web
  GhPagesDeployTarget(),                  // oka run publish-gh-pages
],
```

One codebase, one composition — no per-store branches. Full walkthrough:
the [web shell station guide](https://docs.page/arenukvern/oka/guides/web_shell_station).

## The agent surface

Every operation is checkable and scriptable — this is what "AI-native"
means here, not a chat wrapper:

```
| Command | What an agent gets |
|---|---|
| `oka explain` / `oka build --dry-run` | The validated plan: steps, artifact chain, signing, versions — zero tools invoked |
| `oka explain --targets` | Every project-declared target with its compiled step chain (ADR-0015) |
| `oka debug step <name>` | One pipeline step re-run against `.oka_cache` — 10-minute loops become 30-second probes |
| `oka compare a.apk b.apk` | Byte-equivalence gate (badging + zip entries) — refactors prove, not claim |
| `oka cache list/gc/why` | Inspectable views over the shared artifact store (ADR-0013) |
| `oka doctor` | Full environment + build-health audit, including secret-tier and dev-loop readiness |
```

## Configuration

Config is a typed Dart entrypoint — programmable, refactorable,
agent-writable:

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
artifacts; the whole chain is validated **before any tool runs**. Copyable
canonical config: [example/tool/oka_pipeline.dart](example/tool/oka_pipeline.dart).

## FAQ

**Do I need Gradle?**
No — ever. The default path never falls back to `flutter build apk`
(enforced by tests). What you give up is real and listed: no full
Gradle/AGP compatibility (AIDL, RenderScript, data binding, NDK), and some
plugins with complex native Android code fail loudly instead of silently
([ADR-0001](docs/decisions/0001-no-gradle-default-build-path.md)) — the
[migration guide](https://docs.page/arenukvern/oka/guides/gradle_migration)
maps what transfers, what needs config, and what oka does not do.

**Does it work with my Flutter version / SDK layout?**
Oka drives `flutter assemble` and the Flutter cache, so it tracks your
installed Flutter SDK (`fvm`-managed included) rather than pinning one. The
Android build-tools/platforms are self-resolved — `oka get android-sdk`
bootstraps a managed SDK into `~/.oka/android-sdk`, or point at an existing
one; resolution order is explicit config → env vars → oka-managed → system,
printed by `oka doctor`. Run `oka doctor` to verify your layout.

**Where is the cache, and can I inspect it?**
Yes — that's the contract ([ADR-0013](docs/decisions/0013-toolchain-provisioning-artifact-store.md)).
The shared store is a plain directory with human-decodable layout
(`~/.oka/store/aapt2/8.0.2-<hash>/…`), relocatable via `OKA_CACHE`;
per-project build outputs stay in `.oka_cache/`. Inspect with `ls` — or
with `oka cache list`, `oka cache gc --older-than=30d`, and
`oka cache why androidx/annotation-jvm/1.9.1`.

**How do secrets work?**
By tier ([ADR-0014](docs/decisions/0014-distribution-targets-secrets-model.md)):
`--dart-define` values are compile-time constants baked into the shipped
binary — non-secrets only. Credential contents (service-account JSON,
keystores) are build-host files referenced **by path**, resolved through
typed config → `OKA_<TARGET>_*` env var → `~/.oka/credentials/<target>/`,
kept out of git and out of every log, plan, and state dump. `oka doctor`
audits define keys against secret-ish patterns.

**Why Dart instead of YAML?**
YAML keys are silent typos; Dart is typed, refactorable, programmable
(flavor logic, shared bases), and exactly as writable by agents as by
humans. `oka.yaml` fast-settings still cover the 90% case — and the design
law is that YAML growth is frozen; everything else is Dart
([ADR-0010](docs/decisions/0010-typed-dart-project-config.md)).

**Which platforms?**
Android is the first and deepest platform — APK and AAB, debug and release,
with the full agent dev loop. Web is served at the
configuration-and-distribution layer (the shell station + deploy targets,
ADR-0016) — the web compile stays an honest delegation to
`flutter build web`. Further platforms (iOS, desktop) are
**criteria-gated**, not calendar-driven: depth before breadth (the dev loop
is the product), no platform detail in `oka_core`, and a new platform only
when an ADR proves the pipeline model maps. Store targets (Play,
AppGallery) are not platforms — they're compositions over the same Android
pipeline. See [the long game](#the-long-game).

## Packages

```
| Package | Purpose |
|---|---|
| [`oka`](https://pub.dev/packages/oka) | CLI + agent surface (this repo) |
| [`oka_core`](https://pub.dev/packages/oka_core) | Platform-agnostic contracts: pipeline, artifacts, composition root, typed config |
| [`oka_android`](https://pub.dev/packages/oka_android) | Android pipelines, toolchain, plugin packaging |
| [`oka_play`](https://pub.dev/packages/oka_play) | Google Play publish target (dry-run-first, path-based credentials) |
| [`oka_huawei`](https://pub.dev/packages/oka_huawei) | AppGallery Connect target (GMS-excluded variant + upload tail) |
| [`oka_web`](https://pub.dev/packages/oka_web) | Web shell station: per-store `web/index.html` as typed Dart, emitters, deploy targets |
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
   cheap third. Web's compile step needs nothing oka-shaped — but its
   configuration and store layer does, served by the ADR-0016 shell
   station without a platform pipeline.

Full charter: [why oka matters](https://docs.page/arenukvern/oka/start_here/why_this_repo_matters).

## Documentation

Published via docs.page: **[docs.page/arenukvern/oka](https://docs.page/arenukvern/oka)**

```
| I want to… | Read |
|---|---|
| Copy-paste the common loops | [Quick recipes](https://docs.page/arenukvern/oka/start_here/quick_recipes) |
| Run/build/test/configure | [Build & configuration guide](https://docs.page/arenukvern/oka/guides/build_and_config) |
| Publish to Play / AppGallery | [Publishing guide](https://docs.page/arenukvern/oka/guides/publishing) |
| Ship a web app to stores / hosting | [Web shell station guide](https://docs.page/arenukvern/oka/guides/web_shell_station) |
| Migrate an existing Gradle app | [Gradle migration guide](https://docs.page/arenukvern/oka/guides/gradle_migration) |
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
