# Why oka matters — north star

**Oka is a declarative, compositional, AI-native build system — easy to set
up for any platform.** Platform builds are typed, immutable values composed
into pipelines that both humans and agents can run, inspect, and fix. Today
the promise is kept for **Android** — the first platform, and the deepest:
a no-Gradle pipeline (`flutter assemble` + Android SDK CLI tools: `aapt2`,
`javac`, `d8`, `zipalign`, `apksigner`) with no daemon, no AGP, no 30s+
configuration overhead.

Three words carry the whole design:

- **Declarative** — a build is described by typed values (`AndroidBuild`,
  `PipelineOverrides`, `ManifestSpec`) composed in a project-owned Dart
  entrypoint (ADR-0010). Configuration is code: type-safe, refactorable,
  copyable between projects, and written just as well by agents as by
  humans. No YAML sprawl, no stringly flags.
- **Compositional** — every capability is a `BuildStep`, a typed value, or a
  resolver service (ADR-0007's design law). Steps declare typed artifacts
  (`requires`/`provides`); the whole chain validates before any tool runs.
  A platform is just another `PlatformPipeline` selected by `--platform`;
  toolchains, provisioning, and caches are contracts with replaceable
  defaults, not baked-in behavior (ADR-0013).
- **AI-native** — the system is operable end-to-end from its own output:
  validated plans (`oka explain`), single-step probes (`oka debug step`),
  byte-equivalence gates (`oka compare`), environment audits (`oka doctor`),
  deterministic artifacts, and failures that name the fix. Success metric:
  *an agent can set up and fix a platform build from oka's messages alone.*

## The problem oka was created for

Not slowness — **lock-in and unmanageability**. The same story on every
platform and OS: an app is one codebase, but building it is scattered across
a dozen configs in different languages and formats — gradle DSL, XML
manifests, properties, plists, proguard rules, signing files. None typed,
none unified, none shareable. Every project re-solves the same problems
(package, versions, icons, permissions, deeplinks, dependency quirks); every
config repeats, drifts, and is effectively impossible to work with across
projects. You don't operate the build — you negotiate with it, behind plugin
DSLs and hidden defaults.

The toolchain lock-in has real costs beyond friction: it makes builds
non-reproducible, hides failure causes behind generated glue, and locks
agents (and humans) out of fixing anything directly.

Oka's bet: **it is all just one code.** The entire build — steps, deps,
manifest, signing, icons — becomes one typed, composable Dart surface that
you own end to end. One code that is readable, refactorable, and copyable
between projects. Speed falls out of that as a consequence (incremental
builds in ~23s, no daemon); simplicity and unification are the point. Each
oka generation moves more per-platform noise — configs, defaults, recovery —
into that single surface, until a platform build is as simple as copying one
Dart file and running one command.

## What oka owns

- The **default build path**: `oka build apk` / `oka build aab` compile,
  package, align, and sign without Gradle — ever.
- **Plugin packaging**: Flutter plugin Java/Kotlin sources, Maven/AAR
  dependencies (including natives + res), `GeneratedPluginRegistrant`.
- **Fast settings**: extra deps, extra assets, deeplinks, adaptive launcher
  icons — all declarative in `oka.yaml`.
- **Dependency recovery**: runtime missing-class crashes map back to Maven
  artifacts automatically.
- **Dev loop (`oka dev`)**: build → install → launch → hot reload/restart
  session, agent-first (headless, structured events) via the flutter_tools
  daemon protocol — [ADR 0011](decisions/0011-hot-reload-run-loop.md),
  [plan](guides/hot_reload_plan.md).
- **Composable environment**: toolchain resolution and provisioning (SDK,
  JDK, build-tools, adb, emulator images) as typed providers, and one
  content-addressed artifact store for shared inputs — inspectable,
  purgeable, replaceable — instead of scattered hidden caches
  ([ADR 0013](decisions/0013-toolchain-provisioning-artifact-store.md)).
- **One stable CLI**: platform-agnostic verbs (`build`, `explain`,
  `doctor`, …) plus project-declared targets (`oka run <target>`) discovered
  from the composition root — typed values that compile to pipelines, so
  custom flows (device, publish, test loops) stay explainable and valid
  ([ADR 0015](decisions/0015-cli-verb-target-split.md)).

## What oka does not own

- Full Gradle/AGP compatibility (AIDL, RenderScript, data binding, NDK).
- iOS/desktop/web builds — **not yet, and criteria-gated** (below); the core
  contracts are already platform-agnostic (ADR-0006 package split).
- **Store API clients and credentials** — publishing targets (Play,
  AppGallery, RuStore) are separate packages composed on top of a platform
  build, with their own ADR (ADR-0013's two-axis law: distribution targets
  are not platforms).
- ~~The Rust/cargo-apk hybrid~~ — removed entirely (ADR-0001 → ADR-0009); only
  the no-Gradle path exists.

## The long game — expanding to other platforms

One platform proves the model; the model is built for many. Expansion is
**criteria-gated, not calendar-driven**:

1. **Depth before breadth.** Android ships the full agent dev loop
   (`oka dev`, ADR-0011) before a second platform starts. The loop is the
   product; a second shallow pipeline would split effort without adding
   users.
2. **Abstraction hygiene as a standing rule.** No platform detail leaks into
   `oka_core`. Any new capability that cannot be expressed as
   `PlatformPipeline` / `BuildStep` / typed value is a design smell to fix
   before shipping it. (`oka explain`, `oka compare`, `oka doctor`,
   `oka debug step` are already platform-agnostic surfaces — they compose
   whatever pipelines exist.)
3. **Two axes, never confused** (ADR-0013). Platforms (`PlatformPipeline`)
   and distribution targets (store uploads, build variants) are orthogonal:
   Play/Huawei/RuStore are *one application on one platform* composed as
   target packages, not platform forks. Toolchains and device layers are
   platform-scoped; the artifact store is the cross-platform primitive.
4. **CLI verbs never know platforms** (ADR-0015). Platform behavior is
   reachable only through pipelines and targets, never inside a verb
   implementation; the core CLI stops growing when new platforms or stores
   arrive as target packages.
5. **Second platform candidate: iOS.** Strongest case — full CLI toolchain
   (`xcodebuild`, `plutil`, `security`, `altool`), highest Flutter demand
   after Android, and signing/provisioning is exactly the friction agents
   handle worst. Gated on an ADR proving the pipeline model maps
   (assemble → compile → codesign → validate) plus real demand signal.
6. **Cheap third: desktop** (e.g. Windows MSIX — production projects already
   use it). **Web needs nothing oka-shaped** — `flutter build web` is
   already declarative and fast; oka adds no value there.
7. **Stay in the wedge.** Oka is not a general build orchestrator (that's
   bazel/just/melos territory). The wedge is Flutter + agent-native +
   no-Gradle. Every expansion should tighten that wedge, not dilute it.

## Invariants

1. The default path must **never** shell out to `flutter build apk` /
   Gradle as success (ADR 0001).
2. Only one build path exists — the no-Gradle pipeline; the cargo-apk hybrid
   was removed (ADR-0009).
3. A phase is done only when tests/evidence exist
   ([PHASE_CHECKLIST](../PHASE_CHECKLIST.md)).
4. Design forks get a decision checkpoint + ADR before coding
   ([decisions](../decisions/index.md)).

## Success looks like

- A project's entire platform build is **one copyable Dart file** — moved
  between projects without re-learning a config format.
- Common Flutter apps (plugins included) build and install with zero Gradle
  on disk — incrementally in seconds, not the 30s+ Gradle tax.
- An agent can set up and fix a build from oka's error messages alone.
