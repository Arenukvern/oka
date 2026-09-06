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
  and written just as well by agents as by humans. No YAML sprawl, no
  stringly flags.
- **Compositional** — every capability is a `BuildStep`, a typed value, or a
  resolver service (ADR-0007's design law). Steps declare typed artifacts
  (`requires`/`provides`); the whole chain validates before any tool runs.
  A platform is just another `PlatformPipeline` selected by `--platform`.
- **AI-native** — the system is operable end-to-end from its own output:
  validated plans (`oka explain`), single-step probes (`oka debug step`),
  byte-equivalence gates (`oka compare`), environment audits (`oka doctor`),
  deterministic artifacts, and failures that name the fix. Success metric:
  *an agent can set up and fix a platform build from oka's messages alone.*

## The problem

Every Flutter Android build pays a Gradle tax: daemon startup, configuration
phase, plugin resolution — before any of your code compiles. Incremental
builds take 30s+ when the actual work is seconds. For AI-assisted and
agentic workflows, where builds run constantly, that tax dominates — and
Gradle's opaque, stateful errors make agents flail.

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

## What oka does not own

- Full Gradle/AGP compatibility (AIDL, RenderScript, data binding, NDK).
- iOS/desktop/web builds — **not yet, and criteria-gated** (below); the core
  contracts are already platform-agnostic (ADR-0006 package split).
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
3. **Second platform candidate: iOS.** Strongest case — full CLI toolchain
   (`xcodebuild`, `plutil`, `security`, `altool`), highest Flutter demand
   after Android, and signing/provisioning is exactly the friction agents
   handle worst. Gated on an ADR proving the pipeline model maps
   (assemble → compile → codesign → validate) plus real demand signal.
4. **Cheap third: desktop** (e.g. Windows MSIX — production projects already
   use it). **Web needs nothing oka-shaped** — `flutter build web` is
   already declarative and fast; oka adds no value there.
5. **Stay in the wedge.** Oka is not a general build orchestrator (that's
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

- Incremental builds 3–5x faster than Gradle.
- Common Flutter apps (plugins included) build and install with zero Gradle
  on disk.
- An agent can fix a broken build from oka's error messages alone.
