# 0006 — Declarative Dart composition API as the single extension surface

- **Status:** proposed
- **Date:** 2026-09-04
- **Decision-makers:** Anton, oka agent
- **Extends:** 0002 (composable build pipeline — implements its staged item 4)
- **Supersedes (draft iteration):** earlier 0006 draft proposing a mutable
  `defaults.insertAfter()` hook API — rejected during design review: list
  surgery is imperative state mutation, not composition.

## Context

ADR-0002 staged extensibility as YAML fast-settings plus an optional Dart
entrypoint. The fast-settings layer works, but every capability request
(manifest fragments, signing extras, platform steps) drifts toward new YAML
keys — a config field per attribute is the Gradle trap. Meanwhile the internal
API cannot support a typed composition layer:

- `BuildContext`, `OkaConfig`, `AndroidConfig`, `FlutterConfig` are extension
  types over `Map<String, dynamic>` — stringly, untyped, no `copyWith`,
  defaults scattered across `jsonDecode` calls.
- `PipelineState` is a string-keyed mutable blackboard; step coupling and
  ordering contracts are invisible; bad keys fail at runtime, not composition.
- `BuildStep` mixes configuration with behavior and digs config out of context
  at run time; steps are not const-constructible values.
- Host manifest attributes are hardcoded in `host_codegen.dart`.
- `lib/oka.dart` exports everything (including AI/HTTP clients); hook authors
  importing oka would drag heavy transitive deps (http, analyzer-sensitive
  trees) into host apps with aggressive `dependency_overrides`.

oka distributes as an AOT snapshot, so user Dart code cannot be loaded
in-process; the hook boundary must be a subprocess.

## Considered options

- **A. More YAML surface.** Rejected: DSL accretion; expression limited to
  what oka anticipated.
- **B. Mutable hook API** (`defaults.insertAfter/replace/remove`). Rejected:
  imperative list surgery; steps mutate a shared plan; ordering contracts
  stay implicit; not declarative, not const.
- **C. In-process loading / wire-protocol plugin registry.** Rejected: fights
  the AOT snapshot; machinery without need (ADR-0002 option C stays deferred).
- **D. Declarative value model** — Flutter's discipline applied to builds:
  immutable const pipelines/steps/specs, typed artifact exchange, a single
  mutable runtime scope, `copyWith` as the only override mechanism. Chosen.

## Decision

Chosen option **D**, staged:

### 1. Value model (external API)

```dart
// tool/oka_pipeline.dart
Future<void> main(List<String> args) => okaRun(
  args, // parses --mode/--aab/--abi/--target + dart-defines; merges oka.yaml
  oka: const Oka(
    pipelines: [
      AndroidPipeline(
        config: AndroidBuild(/* typed spec; copyWith to override */),
        steps: [...AndroidPipeline.standard, MyStep()],
      ),
    ],
  ),
);
```

- `Oka` is the composition root: a const list of `PlatformPipeline`s
  (`AndroidPipeline` now; `oka_ios` etc. later, same shape).
- Pipelines, steps, and config specs are **immutable, const-constructible
  values**. Configuration enters via constructors (injection), never by
  digging out of context at run time.
- **`copyWith` on typed specs is the only override mechanism.** Precedence:
  code defaults < `oka.yaml` < hook `copyWith`. No string-keyed config, no
  raw-XML patching; the host manifest becomes a typed `ManifestSpec` value
  that `host-codegen` renders.
- `okaRun` performs the boilerplate (arg parsing, yaml merge, SDK resolution,
  cache dirs) and the **composition-time validation** below.

### 2. Typed artifact exchange (internal API)

- `Artifact<T>` typed keys replace `PipelineState`'s string blackboard
  (`flutterAssets = Artifact<Directory>('flutter-assets')`, …).
- Steps declare `requires` / `provides` as artifact sets. The runner validates
  the full chain **before any tool runs** and fails naming the missing
  artifact and its expected producer.
- Pipeline stays a linear phase list (debuggable; matches sequential tool
  invocation); typed artifacts make memoization — and later incremental
  builds — a runtime concern, not an API change.
- `BuildScope` is the only mutable layer: memoized artifact reads, typed
  `HostEnv` (mode, defines, SDK paths, cache dirs), injectable
  `ProcessRunner` so tests run without real SDKs.

### 3. Package split (dependency isolation)

```
oka           → CLI: bin/, AI client, http, global snapshot (heavy)
oka           → core contracts: Oka, BuildStep, Artifact, BuildScope, specs (light)
oka_android   → pipelines, steps, AndroidBuild, Android toolchain (light)
```

- Platform packages keep minimal transitive deps (path/args/yaml class) —
  explicitly no http/analyzer-adjacent trees — so host apps with strict
  `dependency_overrides` can depend on them without resolution conflicts.
- One package per platform (`oka_android`, future `oka_ios`) rather than a
  single `oka_platform` monolith, to avoid re-accumulating a kitchen sink.
- Hooks pin `oka_android` via the project's own `dev_dependencies`; the global
  oka snapshot never determines hook API versions.

### 4. Execution and config freeze

- `oka build` detects a `pipeline.dart_entrypoint` in `oka.yaml` (the only new
  key) and spawns `dart run <entrypoint>` with mode/aab/abi/target/defines via
  args and env. Projects without the key keep the AOT fast path unchanged.
- `pipeline.dart_entrypoint` is the **last** extensibility key oka.yaml gains.
  Future capability requests become hooks, or promoted core steps once two or
  more projects need them.

### 5. Staged implementation (behavior-preserving first)

1. Package split; contracts exported from the core barrel (no `src/` imports
   in user code; barrel contents are semver-covered).
2. Replace map extension types with typed value classes + `copyWith`; JSON
   parsing confined to the CLI/yaml boundary. Tests green at every step.
3. Introduce `Artifact<T>`/`BuildScope`; re-express the 13 default steps as
   const values with requires/provides.
4. Runner validation + `okaRun` entrypoint + delegation.
5. Gate: the default path produces byte-equivalent APKs before and after the
   refactor; the no-Gradle invariant (ADR-0001) is untouched throughout.

## Consequences

Good:
- Extension surface = ordinary Dart + pub packages; declarative, const,
  strictly typed — no DSL accretion, no stringly maps
- Ordering/coupling contracts checked at composition time with actionable
  errors; runtime key typos become compile-time types
- Memoized artifact reads give incremental builds without API churn
- Per-project version pinning; dependency-light platform packages isolate
  host apps from oka's heavy CLI deps
- Any future platform is another `PlatformPipeline` value; oka core stays
  Android-deep until steps prove reusable

Bad / Neutral:
- Sized refactor: every step, config, and the runner change shape; contract
  and source-contract tests must move with it
- Barrel exports become semver contract — discipline required
- Two execution paths (AOT default / `dart run` delegation) to test
- `dart run` adds ~1–3 s cold-start to hooked builds (kernel-cached after)

**Authoritative source:** `lib/src/pipeline/` (contracts), `lib/oka.dart`
(barrel), `bin/oka.dart` + `packages/oka/lib/src/cli/build_command.dart` (delegation),
`oka_android/` (platform package).
