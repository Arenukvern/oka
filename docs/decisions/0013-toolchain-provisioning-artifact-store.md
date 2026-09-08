# 0013 — Toolchain, provisioning, and artifact store as composable surfaces

- **Status:** accepted
- **Date:** 2026-09-06
- **Decision-makers:** Anton, oka agent

## Context

Everything that surrounds the build — locating the SDK, resolving Java,
downloading build-tools and Kotlin, adb, emulators, Maven artifacts — is
today opaque oka behavior, not oka surface. Concretely:

- `SdkLocator` is a god-object: resolution precedence
  (`OKA_ANDROID_SDK` → `~/.oka/android-sdk` → `ANDROID_HOME` → common paths)
  is encoded in control flow — invisible, untestable, unprintable. It also
  downloads (ad-hoc `curl`, three near-identical methods) and even reads
  `stdin` interactively inside the build path — CI-breaking and agent-hostile.
- Caching is scattered across at least four disconnected stores:
  `<buildDir>/step_cache.json` (per-project, well-designed),
  `~/.oka/cache/androidx`, `~/.oka/tools`, and the dependency cache. Nothing
  is inspectable or purgeable as a unit; nothing is shareable across projects
  except by accident of path.
- Demand exists for device/emulator orchestration and store publishing
  (Google Play, Huawei AppGallery, RuStore), each of which forces more
  toolchain setup today. Doing these as more baked-in behavior would grow the
  black box oka exists to eliminate.

Framing analogy: **Nix semantics, Flutter ergonomics.** Take from Nix the
inspectable, addressable store and plans that can be evaluated without
executing. Leave behind Nix's own language, laziness, and purity dogma —
oka composes typed Dart values with sensible defaults instead.

## The two-axis model

A central correction drives this ADR: **distribution targets are not
platforms.**

```
Platform axis (PlatformPipeline, --platform):
  android (today) · ios · harmony · linux · windows · web   ← criteria-gated (north star)

Distribution axis (targets composed ON a platform build):
  sideload · play · huawei · rustore · ci-upload · ...
```

- Google Play / Huawei / RuStore builds are **one application** on one
  platform; a store target = a **build-variant composition** (e.g. Huawei:
  no GMS deps, `agconnect-services.json`, its own signing rules) **plus a
  publish tail** (upload API, metadata). These are separate packages
  (`oka_play`, `oka_huawei`, …) depending on `oka_core` + the platform
  package — never a fork of the platform pipeline, never a "Play pipeline"
  vs "Huawei pipeline" split.
- Toolchains (Android SDK, NDK, adb, emulators, JDK) are
  **platform-scoped providers**. The artifact store is the one primitive
  that is cross-platform by nature and therefore lives in `oka_core`.

## Decision

Chosen: **contracts in core, components in packages, defaults as
replaceable implementations.**

1. **`oka_core` gains three small contracts** (kernel stays ruthlessly
   small — same discipline as `universal_storage_interface`):
   - `ArtifactStore` + `ContentKey` — content-addressed storage:
     `key = hash(inputs) + toolVersion + platform`. Implementations fetch
     through `fetch(key, miss)`.
   - `Toolchain` / `ToolProvider` — tool resolution becomes **data**: an
     ordered, printable resolution policy (explicit config → env vars →
     oka-managed roots → system), and provisioning that must go through the
     store. `oka doctor` prints the resolved policy; `oka explain` stays
     tool-free.
   - A `ResolvedToolchain` artifact injected into steps via the existing
     `PipelineState` — no step calls a god-object.
2. **Default implementations ship as components, not behavior:** a plain
   `LocalArtifactStore` (directory + JSON index, human-decodable layout like
   `~/.oka/store/aapt2/8.0.2-<hash>/bin/aapt2` — inspectable with plain
   `ls`/`find`/`du`), and Android tool providers in `oka_android`.
3. **Cache scope rule:** share **inputs** across projects (SDKs, NDK, Maven
   artifacts, emulator images — `OKA_CACHE`-pointable for team/network
   sharing); **outputs** stay per-project in `buildDir/` (cross-machine
   output caches are where nondeterminism lives). The four scattered caches
   unify behind `ArtifactStore`.
4. **No stdin in any build path, ever.** Interactivity is only an explicit
   opt-in policy/flag; otherwise steps fail with `StepResult.failure`
   naming the fix (agent-first law, ADR-0007).
5. **`oka cache list / gc / why` are views over the interface** — and the
   Dart API (`store.entries()`) is the real agent surface: agents script the
   store in ten lines instead of learning subcommands.
6. **Distribution targets are deferred to their own ADR (0014)** — store API
   clients, auth/secret handling, and metadata formats are a design area of
   their own. This ADR only fixes the axis and the package boundary
   (`oka_play`/`oka_huawei` as target packages).
7. **`Target` grouping in the composition root is deferred.** Targets ship
   as `Pipeline`s first; a grouping concept can be added later but never
   removed.

### What oka does / does not do (scope law)

Oka **does**: composable toolchain resolution + provisioning, a content-
addressed artifact store with replaceable defaults, platform pipelines, and
device/emulator lifecycle as pipeline steps (platform-scoped).

Oka **does not**: own store API clients or credentials (target packages,
ADR-0014), act as a general orchestrator (bazel/just/melos territory), or
promise Nix-grade reproducibility proofs — inspectability is the default,
purity is not dogma.

## Alternatives considered

- **Bake cache/toolchain/emulator behavior into oka** — rejected: it is the
  black box being solved; control requires contracts, not features.
- **Everything configurable (Gradle-style knob zoo)** — rejected: recreates
  the config sprawl oka replaces; typed values + composition win.
- **Store targets as platforms** (`GooglePlayPipeline` vs
  `HuaweiPipeline`) — rejected: wrong axis; both are one Android app, and
  treating stores as platforms would fork toolchains and force the split
  onto every future store.

## Consequences

Good:
- Cache stops being a black box: known key function, self-describing layout,
  one interface to inspect/purge/replace/share.
- Env-var precedence becomes printable data (doctor), testable, and
  overridable per project without editing oka.
- Emulator/device and future store work compose over the same kernel —
  no new mechanisms.
- Third-party target/toolchain packages become possible and gateable
  (conformance tests: dry-run without credentials, no stdin, no secrets in
  state — mirrors the `universal_storage_conformance` pattern).

Bad / Neutral:
- New quasi-public API in `oka_core` → semver discipline on the kernel.
- Migration cost: `SdkLocator` dissolution touches every tool step;
  behavior-preserving refactor first, byte-equivalence gates (`oka compare`)
  as evidence.
- Two store layers to explain (per-project `StepCache` vs shared
  `ArtifactStore`) — documented distinction: outputs vs inputs.

## Phased plan

Tracked in `docs/PHASE_CHECKLIST.md` (T0–T3). Distribution-target ADR
(0014) is a separate checkpoint, gated on T0/T1 landing.

**Authoritative source:** `packages/oka_core` (contracts), this ADR,
`docs/PHASE_CHECKLIST.md` (progress).
