# Oka — one typed Dart surface to build, run, patch, and distribute apps

<p align="center">
  <img src="docs/images/oka-banner.svg" alt="Oka: one typed Dart file, no Gradle, Flutter Android builds" width="720" />
</p>

[![skills.sh](https://skills.sh/b/arenukvern/oka)](https://skills.sh/arenukvern/oka)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-docs.page-02569B)](https://docs.page/arenukvern/oka)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/arenukvern/oka)
[![CI](https://github.com/Arenukvern/oka/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Arenukvern/oka/actions/workflows/ci.yml)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.44-blue.svg)](https://flutter.dev)
[![All Contributors](https://img.shields.io/github/all-contributors/Arenukvern/oka?color=ee8449&style=flat-square)](https://github.com/Arenukvern/oka#contributors-)
<a title="Discord" href="https://discord.com/invite/y54DpJwmAn" ><img src="https://img.shields.io/discord/696688204476055592.svg" /></a>
[![maintained with Skill Steward](https://raw.githubusercontent.com/Arenukvern/skill_steward/main/docs/brand/assets/svg/badge-light.svg)](https://github.com/Arenukvern/skill_steward)

> **TL;DR** — Oka is a declarative application platform: one typed Dart file
> you own (`tool/oka_pipeline.dart`) composes the whole loop — build without
> Gradle, run on devices, patch running programs live, supervise processes,
> and publish to stores. Humans and agents operate it identically: every
> operation has a plan you can read (`oka explain`), a probe you can run
> (`oka debug step`), and failures that name the fix.
> `oka init` → `oka build apk` → `oka run device`.

**Who it's for:** Flutter teams and release engineers who want a single
inspectable build surface; agents and CI that need `oka explain` and
actionable errors; anyone shipping store-free updates to installed apps.
Not a full Gradle/AGP emulator — see [FAQ](docs/FAQ.md) and
[charter](docs/start_here/why_this_repo_matters.mdx).

## Four pillars, one surface

Oka started as a no-Gradle Android build system. The same laws — typed
values, validated plans, evidence over demos — now carry three more
pillars, each at a different, honestly-labeled maturity:

| Pillar | What it does | Maturity |
|---|---|---|
| **Build** | No-Gradle APK/AAB: `flutter assemble` + direct SDK tools, provenance on every artifact, byte-equivalence gates | **Production** — on pub.dev (v0.8.0) |
| **Distribute** | Play / AppGallery / RuStore / web stores, multiple developer accounts, white-label brands — dry-run by default | **Production** — on pub.dev |
| **Update** | Live per-unit patching of **running** programs: the `oka run dev` session, `oka ship` store-free air channel, AOT slots | **Gate-proven experimental** — runs from a checkout |
| **Operate** | Declarative supervisor, process leases, session-state, content-addressed artifact store with delta chains | **Production** — supervisor at adoption rung L0 |

The design laws are constant across pillars: configuration is typed Dart
you own, every chain validates before any tool runs, and *an agent can set
up and fix things from oka's messages alone*. The full north star,
invariants, and expansion gates live in the
[charter](docs/start_here/why_this_repo_matters.mdx).

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
`tool/oka_pipeline.dart`, run `oka`.** Start anywhere.

### Build 1 — Daily dev loop: hot reload without Gradle

```bash
oka build apk --debug   # once
oka dev                 # r hot reload · R hot restart · q quit · d detach
oka dev --watch --json  # agents: Dart edits auto-reload; native edits print
                        # the honest full-rebuild command
```

Hot reload is Dart-only — native/res/manifest changes need a rebuild
([ADR-0011](docs/decisions/0011-hot-reload-run-loop.mdx)).

### Build 2 — Release builds: proven, not hoped

```bash
oka build apk --release          # AOT + R8 + signed (mapping.txt included)
oka build aab --release --verify-aab   # store upload format, bundletool-verified
oka run verify                   # prove the release actually starts on a device
oka compare old.apk new.apk      # byte-equivalence gate for refactors
```

Every artifact carries `oka-provenance.json` (engine + snapshot hashes); a
wrong engine/snapshot pairing fails the build instead of hanging the device
on a splash screen ([ADR-0029](docs/decisions/0029-build-provenance-and-verification-ladder.mdx)).

### Distribute 3 — Stores: one app, many stores

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

### Distribute 4 — Multiple accounts & white-labeling

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

### Distribute 5 — Web: shell station, not a platform

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

### Update 6 — Live patching: change running programs

The kernel/update stack (`oka_dart_kernel` + `oka_update`) applies changes to
**running** Dart programs — and ships patches to installed ones without a
store ([ADR-0037](docs/decisions/0037-air-channel-invisible-patches.mdx)).
Proven by the gate harness across macOS/linux/android/web and three real
products (the oka CLI itself, an MCP stdio server, a Flutter desktop app).
A full live apply lands in **0.57 s**; AOT deltas compile ~94x faster than
JIT.

```bash
oka run dev --platform macos --project <app>   # r = oka's delta lane, R = restart
oka ship                                       # derive + publish a patch from the working tree
packages/oka_dart_kernel/example/live_showcase/run.sh   # 30 s demo
```

Works today: the dev session (macOS/web) with watch-on-save, asset sync,
and live shader recompiles; invisible patch authoring; signed channels;
migration chains with snapshot fallback; the boot watchdog; command lanes on
the watcher. Not yet: the android dev session convergence, live freshness
for already-loaded assets (engine seam), per-unit AOT over the air
(research line, ADR-gated). The update stack itself is not on pub.dev — it
runs from an oka repo checkout; everything it patches can be a plain pub
app.

Guide: [Live update](docs/guides/live_update.mdx).

### Operate 7 — Supervise, lease, store

```bash
oka supervisor apply plan.json   # one converge pass over a declared plan
oka supervisor status --json     # recorded process state as data
oka supervisor check plan.json   # plan-vs-records drift gate for CI
oka processes list --json        # every lease oka recorded (emulators, browsers, daemons)
oka stop <lease-id>              # graceful, identity-verified teardown
oka artifacts put out.bin        # content-addressed store; git keeps a pointer
oka artifacts materialize out.bin # recreate bytes anywhere (delta chains, ~0.03% deltas)
```

Supervisor plans are versioned JSON (`SpecCodec`); the shipped rung is
one-shot converge — no resident daemon (that is ADR-0042, proposed and
gated). Guides: [Supervisor](https://docs.page/arenukvern/oka/guides/supervisor) ·
[Process lifecycle](https://docs.page/arenukvern/oka/guides/process_lifecycle) ·
[Artifacts](https://docs.page/arenukvern/oka/guides/artifacts).

## The agent surface

This is what "AI-native" means — every operation is checkable and scriptable:

| Command | What an agent gets |
|---|---|
| `oka explain` / `oka build --dry-run` | The validated plan: steps, artifacts, signing, versions — zero tools invoked |
| `oka explain --targets` | Every project-declared target with its compiled step chain |
| `oka why <step>` | Step-cache forensics: fingerprinted inputs, which changed, what's uncovered |
| `oka debug step <name>` | One pipeline step re-run against `.oka_cache` — 10-minute loops become 30-second probes |
| `oka compare a.apk b.apk` | Byte-equivalence gate — refactors prove, not claim |
| `oka cache --json` / `oka cache clean` | Storage inventory and reclaimable totals as data |
| `oka run dev --json` | Dev-session receipts: reload/restart events as structured lines |
| `oka ship` | Derive + publish a store-free patch from the working tree (checkout) |
| `oka supervisor status --json` / `check plan.json` | Recorded process state and the plan-vs-records drift gate as data |
| `oka processes --json` / `oka stop` | Process leases as data; graceful identity-verified teardown |
| `oka session-state list/inspect/resume` | Durable browser/emulator state as inspectable data |
| `oka_artifacts` (package CLI: put/materialize/verify) | Build artifacts as pointers + delta chains — git stays small, LFS optional |
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

<p align="center">
  <img src="docs/images/pipeline-flow.svg" alt="Diagram: oka_pipeline.dart to flutter assemble and Android SDK tools, output APK or AAB" width="720" />
</p>

<p align="center">
  <img src="docs/images/cli-help-example.svg" alt="Example terminal session: oka explain, build, and doctor" width="560" />
</p>

Source: [`docs/images/pipeline-flow.mmd`](docs/images/pipeline-flow.mmd) (Mermaid).

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
project with a five-minute README (step 6 is a guided demo that runs from
this checkout):

| Step | You learn |
|---|---|
| [01 hello app](examples/01_hello_app) | Smallest possible oka build (one Dart file, one command) |
| [02 dev loop](examples/02_dev_loop) | Hot reload / hot restart with `oka dev` |
| [03 release](examples/03_release_signing) | Release signing, R8, `oka run verify` |
| [04 stores & accounts](examples/04_stores_accounts) | Play + AppGallery + RuStore, two Play accounts, white-label brands |
| [05 web stores](examples/05_web_stores) | Web shell, GitHub Pages, itch.io |
| [06 live patch](examples/06_live_patch) | Patch a running app via the air channel (demo runs from this checkout) |

The full reference app remains [example/](example/) — every feature composed
in one file.

## FAQ

Short answers live in **[docs/FAQ.md](docs/FAQ.md)** (also on the
[docs site](https://docs.page/arenukvern/oka/FAQ)). Highlights:

**Do I need Gradle?** No — ever. The default path never falls back to
`flutter build apk` (enforced by tests). What you give up is listed honestly:
no full AGP compatibility (AIDL, RenderScript, data binding, NDK); some
plugins with complex native code fail loudly instead of silently
([ADR-0001](docs/decisions/0001-no-gradle-default-build-path.mdx)).

**Which platforms?** Android is the deepest (APK + AAB, full dev loop). Web
gets the configuration/distribution layer (shell station + deploy targets);
its compile stays `flutter build web`. The update stack already patches
plain Dart programs on macOS/linux/web. iOS/desktop builds are
criteria-gated, not calendar-driven — depth before breadth.

**Where's the cache?** Project outputs in `.oka_cache/`, shared store in
`~/.oka/store`. `oka cache` inventories everything (including emulator
data); `oka cache clean` previews before deleting.

**Why Dart, not YAML?** YAML keys fail silently; Dart is typed, refactorable,
and as writable by agents as by humans. `oka.yaml` covers the 90% case and
its growth is frozen ([ADR-0010](docs/decisions/0010-typed-dart-project-config.mdx)).

Design rationale: [Design FAQ](https://docs.page/arenukvern/oka/guides/design_faq).
Agents: [`llms.txt`](llms.txt) and [`AGENTS.md`](AGENTS.md).

## Packages

Twelve packages ride the automated release train on pub.dev; the live-update
kernel stack is checkout-only while its API settles.

| Package | Pub | Purpose |
|---|---|---|
| [`oka`](https://pub.dev/packages/oka) | ✅ | CLI + agent surface |
| [`oka_core`](https://pub.dev/packages/oka_core) | ✅ | Platform-agnostic contracts: pipeline, artifacts, typed config |
| [`oka_android`](https://pub.dev/packages/oka_android) | ✅ | Android pipelines, toolchain, plugin packaging |
| [`oka_play`](https://pub.dev/packages/oka_play) | ✅ | Google Play publish target |
| [`oka_huawei`](https://pub.dev/packages/oka_huawei) | ✅ | AppGallery Connect target (GMS-free variant + upload) |
| [`oka_rustore`](https://pub.dev/packages/oka_rustore) | ✅ | RuStore target (readiness + verification; adapter-supplied upload) |
| [`oka_web`](https://pub.dev/packages/oka_web) | ✅ | Web shell station + deploy targets |
| [`oka_conformance`](https://pub.dev/packages/oka_conformance) | ✅ | The contract suite every target must pass |
| [`oka_supervisor`](https://pub.dev/packages/oka_supervisor) | ✅ | Declarative supervisor: pure planner + crash-only converge |
| [`oka_artifacts`](https://pub.dev/packages/oka_artifacts) | ✅ | Content-addressed artifact store with delta chains |
| [`oka_harness`](https://pub.dev/packages/oka_harness) | ✅ | Device E2E targets over oka dev sessions |
| [`resource_composition`](https://pub.dev/packages/resource_composition) | ✅ | Zero-dependency resource composition contracts |
| `oka_dart_kernel` | checkout | Kernel-graph partitioning + live-patch gates (ADR-0032) |
| `oka_update` | checkout | Patch-unit authoring/planner surface (ADR-0031) |

## Documentation

Published via docs.page: **[docs.page/arenukvern/oka](https://docs.page/arenukvern/oka)**

| I want to… | Read |
|---|---|
| Newcomer questions | [FAQ](docs/FAQ.md) · [docs.page/FAQ](https://docs.page/arenukvern/oka/FAQ) |
| Copy-paste the common loops | [Quick recipes](https://docs.page/arenukvern/oka/start_here/quick_recipes) |
| Run/build/test/configure | [Build & configuration guide](https://docs.page/arenukvern/oka/guides/build_and_config) |
| Publish to stores, set up accounts | [Publishing](https://docs.page/arenukvern/oka/guides/publishing) · [Accounts & stores](https://docs.page/arenukvern/oka/guides/accounts_and_stores) |
| Ship a web app | [Web shell station guide](https://docs.page/arenukvern/oka/guides/web_shell_station) |
| Patch running apps / ship updates | [Live update](https://docs.page/arenukvern/oka/guides/live_update) |
| Govern daemons, watchers, automations | [Supervisor guide](https://docs.page/arenukvern/oka/guides/supervisor) |
| Manage processes, emulators, browsers | [Process lifecycle](https://docs.page/arenukvern/oka/guides/process_lifecycle) |
| Keep build binaries out of git | [Artifacts guide](https://docs.page/arenukvern/oka/guides/artifacts) |
| Know why it's designed this way | [Design FAQ](https://docs.page/arenukvern/oka/guides/design_faq) |
| Where oka is going | [Roadmap](https://docs.page/arenukvern/oka/start_here/roadmap) |
| Check phase status | [`docs/PHASE_CHECKLIST.mdx`](docs/PHASE_CHECKLIST.mdx) |

## Contributing

Contributions of any kind welcome — code, docs, examples, bug reports, ideas.
See [`CONTRIBUTING.md`](CONTRIBUTING.md) and the
[contribution guide](https://docs.page/arenukvern/oka/contributing/contribution_guide);
use conventional commits (`feat:`, `fix:`, `docs:`) and run
`just check-contracts` before merging. Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md). Agents: start from
[`AGENTS.md`](AGENTS.md) or [`llms.txt`](llms.txt).

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

MIT — see [LICENSE](LICENSE). Changelog:
[`packages/oka/CHANGELOG.md`](packages/oka/CHANGELOG.md) (index:
[`CHANGELOG.md`](CHANGELOG.md)).
