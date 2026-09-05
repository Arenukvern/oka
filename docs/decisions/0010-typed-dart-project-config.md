# 0010 — Typed per-project config in Dart (oka.yaml becomes optional)

- **Status:** accepted
- **Executed:** 2026-09-05 — all stages landed; byte-equivalence gate passed
  (see Consequences)
- **Date:** 2026-09-05
- **Decision-makers:** Anton
- **Extends:** 0006 (declarative Dart composition API), 0007 (self-resolving builds)

## Context

ADR-0006 made the Dart entrypoint the extension surface, but the *base*
per-platform config (`android:` SDK levels, package name, ABIs, versions;
`flutter:` entrypoint, build args) still lives in `oka.yaml`. The hook only
overrides fast-settings (`PipelineOverrides`). YAML stays the single source
of truth for the parts every project must set — stringly, untyped, and not
programmable (no conditionals, no sharing, no code-reuse across flavors).

Research question: can the whole per-platform config move into the project's
Dart pipeline file, strictly typed, with `oka.yaml` becoming optional?

### What oka.yaml actually carries (audited, example app)

| Section | Consumed via | Typed today? |
|---|---|---|
| `android:` SDK levels, package_name, version_code/name, java_version, abis, source_dirs | `ctx.config.android.*` (~30 sites across toolchain/steps/lint/signing) | Read-side view only (`AndroidConfig` extension type over map) — **no writable value** |
| `android:` icon, manifest, res_dirs, signing | `PipelineOverrides.fromOkaYaml` → `IconConfig`/`ManifestSpec`/`SigningConfig` | ✅ fully typed (ADR-0006) |
| `pipeline:` extra_deps/assets, deeplinks, local_aars, resource_configs, exclude_plugins, max_size_mb | `PipelineOverrides` | ✅ fully typed + `copyWith` |
| `flutter:` entrypoint, build_args, target_platform, tree_shake_icons | `ctx.config.flutter.*` | Read-side view only |
| `name`/`version` | cosmetic / pubspec fallback exists (ADR-0007) | — |

### The key seam (why this is cheap)

**Every config consumer reads `ctx.config` — an `OkaConfig` extension type
over `Map<String, dynamic>` with `toJson() => value`.** A typed Dart config
value that can materialize that map (same shape as today's YAML doc) plugs in
without touching a single step, tool invocation, or fingerprint. The pipeline
cannot tell whether the map came from YAML or from Dart.

### Missing pieces (the actual work)

1. **Writable typed values.** `AndroidConfig`/`FlutterConfig` are read views.
   Need const-constructible `AndroidBuild` / `FlutterBuild` values with
   defaults, `copyWith`, and `toMap()` emitting the oka.yaml-shaped map.
2. **Precedence in `okaRun`.** Today it always calls `loadOkaYaml`. Needs:
   code defaults < `oka.yaml` (if present) < Dart `AndroidBuild` < CLI args
   (mode/abi/target/defines, unchanged).
3. **Hook discovery without oka.yaml.** `oka build` requires `oka.yaml` today
   (entrypoint key lives there). A full-Dart project needs a discovery rule
   that adds **no new YAML key** (0006 law).
4. **`oka doctor`** tolerates missing `oka.yaml` already (prints a warning) —
   should recognize a discovered entrypoint instead.

## Decision (proposed)

1. **`AndroidBuild` + `FlutterBuild`** typed values in `oka_core`: const
   constructors carrying the defaults currently scattered across parsers
   (minSdk 21, java 11, abis `[arm64-v8a, armeabi-v7a]`, …), `copyWith`, and
   `toMap()`. `AndroidPipeline` gains `config:` (null → yaml-only, today's
   behavior).
2. **`okaRun` merges**: `AndroidPipeline.config.toMap()` deep-merged over
   `loadOkaYaml()`'s map over `OkaConfig.empty`. Steps, caches, lint,
   version fallback: unchanged — they keep reading `ctx.config`.
3. **Hook discovery (no new YAML):** when `oka.yaml` is absent, `oka build` /
   `oka explain` / `oka doctor` look for `tool/oka_pipeline.dart` (then
   `bin/oka_pipeline.dart`). Present + `oka.yaml` absent → delegate like the
   `dart_entrypoint` path. Neither present → today's "run `oka init`" error.
4. **`oka init --from-yaml`**: converts an existing `oka.yaml` into a typed
   entrypoint 1:1 (this is the migration tool for **last_answer**). `oka init`
   (fresh) gains `--dart` to scaffold the entrypoint instead of YAML.
5. **YAML stays fully supported.** No removal, no deprecation yet — full-Dart
   is opt-in per project. Precedence is printed in `oka explain` so dual
   sources of truth are never silent.
6. **Staging:**
   - Stage 1 — `oka_core` values + `okaRun`/`AndroidPipeline.config` merge +
     tests (behavior-preserving: no project changes).
   - Stage 2 — **example app first target** (executed): all three sections
     moved into `example/tool/oka_pipeline.dart` (discovery convention),
     `oka.yaml` deleted. Equivalence gate: same-hook A/B (config from
     oka.yaml vs from `AndroidBuild`) → badging, `AndroidManifest.xml`,
     `resources.arsc`, `classes.dex` **byte-identical**; only the example's
     timestamped `build_info.txt` stamp (custom step) and its signature
     cascade differ.
   - Stage 3 (executed here): `oka init --from-yaml` converter landed —
     run it in the last_answer repo to migrate (`oka explain --deps` +
     `oka compare` as gates). **Stage 4 (executed):** discovery in `oka
     build`/`explain`/`doctor`; `oka debug step` materializes hook config
     via `okaRun --print-config`.
   - Stage 4 — `oka doctor`/`init` discovery support.

## Consequences

Good: strictly typed, programmable config (flavor logic, shared base configs
as Dart values, compile-time typos instead of silent YAML key typos); oka.yaml
sprawl frozen for good; the hook owns *everything*, not just overrides; zero
step-layer changes thanks to the map seam.

Bad / Neutral: two config sources during transition (mitigated by printed
precedence in explain); `toMap()` re-couples the typed values to the legacy
map shape — acceptable: that map is the de-facto internal contract, and
`AndroidConfig`/`FlutterConfig` views already encode it; projects mixing both
sources must understand precedence (documented + printed).

**Authoritative source:** `packages/oka_core/lib/src/config/` (new typed
values), `packages/oka_core/lib/src/oka_run.dart` (merge),
`packages/oka_android/lib/src/android_pipeline.dart` (`config:`),
`lib/src/cli/` (discovery, `oka init --from-yaml`).
