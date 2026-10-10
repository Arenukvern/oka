# Oka — one code for every platform build

[![skills.sh](https://skills.sh/b/arenukvern/oka)](https://skills.sh/arenukvern/oka)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-docs.page-02569B)](https://docs.page/arenukvern/oka)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/arenukvern/oka)
[![CI](https://github.com/Arenukvern/oka/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Arenukvern/oka/actions/workflows/ci.yml)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.44-blue.svg)](https://flutter.dev)
[![All Contributors](https://img.shields.io/github/all-contributors/Arenukvern/oka?color=ee8449&style=flat-square)](https://github.com/Arenukvern/oka#contributors-)
<a title="Discord" href="https://discord.com/invite/y54DpJwmAn" ><img src="https://img.shields.io/discord/696688204476055592.svg" /></a>
[![maintained with Skill Steward](https://raw.githubusercontent.com/Arenukvern/skill_steward/main/docs/brand/assets/svg/badge-light.svg)](https://github.com/Arenukvern/skill_steward)

> **TL;DR** — Oka replaces Gradle for Flutter Android builds with one typed
> Dart file you own: `oka init` → `oka build apk` → `oka run device`.
> No daemon, no AGP, no YAML sprawl. Stores (Play / AppGallery / RuStore /
> web) and multiple developer accounts are just more values in the same file.

---

## Why oka is different

Your app is one codebase — but building it is scattered across Gradle DSL,
XML manifests, plists, proguard rules, and per-store index.html surgery.
None of it typed, all of it drifting. **Oka collapses all of that into one
typed, copyable Dart file** that both humans and AI agents can run, inspect,
and fix.

| | Gradle + AGP | Oka |
|---|---|---|
| Config | 5+ formats, hidden defaults | One typed Dart file, in your repo |
| Every build pays | ~30s daemon/configuration tax | Direct SDK tools, ~23s incremental |
| First build | Works by convention, breaks mysteriously | `oka explain` shows the whole plan **before** any tool runs |
| When it fails | Generated glue hides the cause | The error names the failing step and the fix |
| Stores & accounts | Per-store branches and gradle flavors | More targets in the same file — dry-run by default |
| AI agents | Fight the build | Built for them: plans, probes, byte-equivalence gates |

Three words carry the design:

- **Declarative** — the build is typed values (`AndroidBuild`, `ManifestSpec`,
  …) in a project-owned `tool/oka_pipeline.dart`. Config is code: checkable,
  diffable, copyable between projects.
- **Compositional** — every capability is a `BuildStep` with declared
  inputs/outputs; the whole chain is validated before any tool runs. A store
  target or a platform is another package over the same kernel.
- **AI-native** — self-describing plans, single-step probes, byte-equivalence
  gates, failures that name the fix. *An agent can set up and fix a build
  from oka's messages alone.*

## 60-second start

```bash
# 1. Install (needs Dart, not Flutter)
dart pub global activate oka        # or: curl -fsSL https://raw.githubusercontent.com/Arenukvern/oka/main/install.sh | bash

# 2. One-time Android SDK bootstrap (into ~/.oka/android-sdk)
oka get android-sdk && oka doctor

# 3. In your Flutter project: scaffold config, build, run
oka init
oka build apk --release             # → .oka_cache/build/release/app-release.apk
oka run device                      # install → launch → crash-log scan
```

Migrating an existing Gradle app? [Migration guide](https://docs.page/arenukvern/oka/guides/gradle_migration)
(same `android/key.properties` and plugins keep working).

## Pick your path

Every path below is the same two moves: **add values to
`tool/oka_pipeline.dart`, run `oka run <target>`.** Start anywhere.

### 1. Daily dev loop — hot reload without Gradle

```bash
oka build apk --debug   # once
oka dev                 # r hot reload · R hot restart · q quit · d detach
oka dev --watch --json  # agents: Dart edits auto-reload; native edits print
                        # the honest full-rebuild command
```

Hot reload is Dart-only — native/res/manifest changes need a rebuild
([ADR-0011](docs/decisions/0011-hot-reload-run-loop.mdx)).

### 2. Release builds — proven, not hoped

```bash
oka build apk --release          # AOT + R8 + signed (mapping.txt included)
oka build aab --release --verify-aab   # store upload format, bundletool-verified
oka run verify                   # prove the release actually starts on a device
oka compare old.apk new.apk      # byte-equivalence gate for refactors
```

Every artifact carries `oka-provenance.json` (engine + snapshot hashes); a
wrong engine/snapshot pairing fails the build instead of hanging the device
on a splash screen ([ADR-0029](docs/decisions/0029-build-provenance-and-verification-ladder.mdx)).

### 3. Stores — one app, many stores

Publish targets are project-declared values, **dry-run by default**: the plan
prints endpoint, track, artifact, and metadata with zero HTTP and zero
credentials ([ADR-0014](docs/decisions/0014-distribution-targets-secrets-model.mdx)).

```dart
// tool/oka_pipeline.dart
targets: const [
  DeviceTarget(),
  PlayPublishTarget(),                                    // oka run publish-play
  HuaweiPublishTarget(release: HuaweiReleaseConfig(appId: '110012345')),  // GMS-free variant + upload
  RuStorePublishTarget(packageName: 'com.example.app'),   // readiness + verification
],
```

```bash
oka explain --targets        # see every declared target and its step chain
oka build aab --release --verify-aab
oka run publish-play         # rehearsal — flip dryRun: false when ready
```

Credentials are **file paths**, never values: typed config →
`OKA_<TARGET>_*` env var → `~/.oka/credentials/<target>/`. Full console
setup: [Publishing guide](https://docs.page/arenukvern/oka/guides/publishing).

### 4. Multiple accounts & white-labeling — same app, different owners

One codebase → many branded, store-separated apps. Two `PlayPublishTarget`s
with distinct names, package ids, and service accounts is all it takes:

```dart
targets: const [
  // Your account:
  PlayPublishTarget(
    targetName: 'publish-play-acme',
    packageName: 'com.acme.myapp',
    serviceAccountPath: 'keys/play-acme.json',
  ),
  // A client's account (white-label):
  PlayPublishTarget(
    targetName: 'publish-play-client',
    packageName: 'com.client.myapp',
    serviceAccountPath: 'keys/play-client.json',
  ),
],
```

```bash
oka run publish-play-acme     # dry-run plan for account 1
oka run publish-play-client   # dry-run plan for account 2
```

The build side is the same Dart file: declare one `AndroidPipeline` per
brand (different `packageName`/`applicationId`, keystore, icon) and pick it
in `main()` from your own flag — it's a program, not a DSL. Recipes and
caveats: [Accounts & stores guide](https://docs.page/arenukvern/oka/guides/accounts_and_stores).

### 5. Web — shell station, not a platform

Per-store `web/index.html` as typed, drift-checked Dart. One composition, no
per-store branches ([ADR-0016](docs/decisions/0016-web-shell-station-store-contributions.mdx)):

```dart
targets: const [
  WebShellTarget(spec: mySpec, contributions: [MyStoreContribution()]),
  WebBuildTarget(),      // honest delegation to flutter build web
  GhPagesDeployTarget(), // or ItchDeployTarget() — dry-run by default
],
```

Guide: [Web shell station](https://docs.page/arenukvern/oka/guides/web_shell_station).

### 6. Live patching — shipped behind the checkout, research preview on pub

The kernel/update stack (`oka_dart_kernel` + `oka_update`) applies changes to
**running** Dart programs — and ships patches to installed ones without a
store ([ADR-0037](docs/decisions/0037-air-channel-invisible-patches.mdx)).
Gate-proven on macOS/linux/android/web and three real products. A full live
apply lands in **0.57 s**; AOT deltas compile ~94x faster than JIT.

```bash
oka run dev --platform macos --project <app>   # r = oka's delta lane, R = restart
oka ship                                       # derive + publish a patch from the working tree
packages/oka_dart_kernel/example/live_showcase/run.sh   # 30 s demo
```

Works today: the dev session (macOS/web) with watch-on-save, asset sync,
and live shader recompiles; invisible patch authoring; signed channels;
migration chains with snapshot fallback; the boot watchdog. Not yet: the
android dev session, live freshness for already-loaded assets (engine
seam), per-unit AOT over the air (research line, ADR-gated). The stack is
not on pub.dev — it runs from an oka repo checkout.

Guide: [Live update](docs/guides/live_update.mdx).

## The agent surface

This is what "AI-native" means — every operation is checkable and scriptable:

| Command | What an agent gets |
|---|---|
| `oka explain` / `oka build --dry-run` | The validated plan: steps, artifacts, signing, versions — zero tools invoked |
| `oka explain --targets` | Every project-declared target with its compiled step chain |
| `oka debug step <name>` | One pipeline step re-run against `.oka_cache` — 10-minute loops become 30-second probes |
| `oka compare a.apk b.apk` | Byte-equivalence gate — refactors prove, not claim |
| `oka cache --json` / `oka cache clean` | Storage inventory and reclaimable totals as data |
| `oka supervisor status --json` / `check plan.json` | Recorded process state and the plan-vs-records drift gate as data |
| `oka doctor` | Full environment + build-health audit, secret-tier checks included |

## Configuration in one glance

The whole build config — typed, const, programmable:

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

Prefer YAML? `oka.yaml` fast-settings still work (`oka init --yaml`); migrate
with `oka init --from-yaml`. Precedence: defaults < `oka.yaml` < Dart config
< CLI args. Everything the keys do: [Build & configuration guide](https://docs.page/arenukvern/oka/guides/build_and_config).

## How it works

1. Host checks + codegen (manifest, `MainActivity`, adaptive vector icons)
2. `flutter assemble` (assets / kernel / AOT) — **never** `flutter build apk`
3. Engine `libflutter.so` extraction from the Flutter cache
4. Plugin packaging + Maven/AAR resolution (parallel, deterministic)
5. `aapt2` → `javac`/`kotlinc` → `d8` compile-and-dex (sorted, reproducible)
6. Extra assets, zip staging, `zipalign -p 4`, `apksigner`
7. Layout validation + post-build lint

Every step declares typed `requires`/`provides` artifacts; the chain is
validated before any tool runs. Canonical copyable config:
[example/tool/oka_pipeline.dart](example/tool/oka_pipeline.dart).

## Learn by building: the examples ladder

Start at [examples/](examples/) and climb — each step is a small, runnable
project with a five-minute README:

| Step | You learn |
|---|---|
| [01 hello app](examples/01_hello_app) | Smallest possible oka build (one Dart file, one command) |
| [02 dev loop](examples/02_dev_loop) | Hot reload / hot restart with `oka dev` |
| [03 release](examples/03_release_signing) | Release signing, R8, `oka run verify` |
| [04 stores & accounts](examples/04_stores_accounts) | Play + AppGallery + RuStore, two Play accounts, white-label brands |
| [05 web stores](examples/05_web_stores) | Web shell, GitHub Pages, itch.io |
| [06 live patch](examples/06_live_patch) | Patch a running app via the air channel |

The full reference app remains [example/](example/) — every feature composed
in one file.

## FAQ

**Do I need Gradle?** No — ever. The default path never falls back to
`flutter build apk` (enforced by tests). What you give up is listed honestly:
no full AGP compatibility (AIDL, RenderScript, data binding, NDK); some
plugins with complex native code fail loudly instead of silently
([ADR-0001](docs/decisions/0001-no-gradle-default-build-path.mdx)).

**Which platforms?** Android is the deepest (APK + AAB, full dev loop). Web
gets the configuration/distribution layer (shell station + deploy targets);
its compile stays `flutter build web`. iOS/desktop are criteria-gated, not
calendar-driven — depth before breadth.

**Where's the cache?** Project outputs in `.oka_cache/`, shared store in
`~/.oka/store`. `oka cache` inventories everything (including emulator
data); `oka cache clean` previews before deleting.

**Why Dart, not YAML?** YAML keys fail silently; Dart is typed, refactorable,
and as writable by agents as by humans. `oka.yaml` covers the 90% case and
its growth is frozen ([ADR-0010](docs/decisions/0010-typed-dart-project-config.mdx)).

More: [Design FAQ](https://docs.page/arenukvern/oka/guides/design_faq).

## Packages

| Package | Purpose |
|---|---|
| [`oka`](https://pub.dev/packages/oka) | CLI + agent surface |
| [`oka_core`](https://pub.dev/packages/oka_core) | Platform-agnostic contracts: pipeline, artifacts, typed config |
| [`oka_android`](https://pub.dev/packages/oka_android) | Android pipelines, toolchain, plugin packaging |
| [`oka_play`](https://pub.dev/packages/oka_play) | Google Play publish target |
| [`oka_huawei`](https://pub.dev/packages/oka_huawei) | AppGallery Connect target (GMS-free variant + upload) |
| [`oka_rustore`](https://pub.dev/packages/oka_rustore) | RuStore target (readiness + verification; adapter-supplied upload) |
| [`oka_web`](https://pub.dev/packages/oka_web) | Web shell station + deploy targets |
| [`oka_conformance`](https://pub.dev/packages/oka_conformance) | The contract suite every target must pass |
| `oka_supervisor`, `resource_composition` | Declarative process supervision + the composition substrate (governance stack) |
| `oka_dart_kernel`, `oka_update`, `oka_harness` | Live-patching / harness stack (experimental, not on pub) |

## Documentation

Published via docs.page: **[docs.page/arenukvern/oka](https://docs.page/arenukvern/oka)**

| I want to… | Read |
|---|---|
| Copy-paste the common loops | [Quick recipes](https://docs.page/arenukvern/oka/start_here/quick_recipes) |
| Run/build/test/configure | [Build & configuration guide](https://docs.page/arenukvern/oka/guides/build_and_config) |
| Publish to stores, set up accounts | [Publishing](https://docs.page/arenukvern/oka/guides/publishing) · [Accounts & stores](https://docs.page/arenukvern/oka/guides/accounts_and_stores) |
| Ship a web app | [Web shell station guide](https://docs.page/arenukvern/oka/guides/web_shell_station) |
| Govern daemons, watchers, automations | [Supervisor guide](https://docs.page/arenukvern/oka/guides/supervisor) |
| Migrate from Gradle | [Migration guide](https://docs.page/arenukvern/oka/guides/gradle_migration) |
| Know why it's designed this way | [Design FAQ](https://docs.page/arenukvern/oka/guides/design_faq) |
| Check phase status | [`docs/PHASE_CHECKLIST.mdx`](docs/PHASE_CHECKLIST.mdx) |

## Contributing

Contributions of any kind welcome — code, docs, examples, bug reports, ideas.
See the [contribution guide](https://docs.page/arenukvern/oka/contributing/contribution_guide);
use conventional commits (`feat:`, `fix:`, `docs:`) and run
`just check-contracts` before merging. Agents: start from
[`AGENTS.md`](AGENTS.md).

## Contributors

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/Arenukvern"><img src="https://github.com/Arenukvern.png?size=100" width="100px;" alt="Arenukvern"/><br /><sub><b>Arenukvern</b></sub></a><br /><a href="#ideas-Arenukvern" title="Ideas, Planning, & Feedback">🤔</a> <a href="#code-Arenukvern" title="Code">💻</a> <a href="#doc-Arenukvern" title="Documentation">📖</a> <a href="#design-Arenukvern" title="Design">🎨</a> <a href="#maintenance-Arenukvern" title="Maintenance">🚧</a> <a href="#review-Arenukvern" title="Reviewed Pull Requests">👀</a> <a href="#test-Arenukvern" title="Tests">⚠️</a></td>
    </tr>
  </tbody>
</table>
<!-- markdownlint-enable -->
<!-- prettier-ignore-end -->
<!-- ALL-CONTRIBUTORS-LIST:END -->

This project follows the
[all-contributors](https://github.com/all-contributors/all-contributors)
specification — any contribution counts, not just code. Add yourself with
`npx all-contributors add <username> <contribution>` (or ask in a PR) and
commit both `README.md` and `.all-contributorsrc`.

## Security

See [`SECURITY.md`](SECURITY.md). Please report vulnerabilities privately.

## License

MIT — see [LICENSE](LICENSE).
