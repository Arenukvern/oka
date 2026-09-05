# Why oka matters — north star

Oka replaces Gradle for Flutter Android builds with a direct pipeline:
`flutter assemble` + Android SDK CLI tools (`aapt2`, `javac`, `d8`,
`zipalign`, `apksigner`). No Gradle daemon, no AGP, no 30s+ configuration
overhead.

## The problem

Every Flutter Android build pays a Gradle tax: daemon startup, configuration
phase, plugin resolution — before any of your code compiles. Incremental
builds take 30s+ when the actual work is seconds. For AI-assisted and
agentic workflows, where builds run constantly, that tax dominates.

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
- iOS/desktop/web builds.
- ~~The Rust/cargo-apk hybrid~~ — removed entirely (ADR-0001 → ADR-0009); only
  the no-Gradle path exists.

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
