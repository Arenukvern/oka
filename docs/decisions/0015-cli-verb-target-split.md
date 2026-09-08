# 0015 — CLI verb/target split and project-declared target discovery

- **Status:** accepted
- **Date:** 2026-09-06
- **Decision-makers:** Anton, oka agent

## Context

The CLI is a hardcoded switch (`bin/oka.dart`) that grows one case per
capability — and platform detail is already leaking into the verb layer:

- `oka launch` performs adb install + logcat scanning (Android device logic
  in a top-level verb).
- `oka get android-sdk` — `get` is generically a provisioning verb, but its
  only noun is Android.
- `oka debug dex` probes DEX symbols in the dispatcher layer.

Continuing this pattern makes the CLI the place where platforms accrete:
iOS (ADR-0013's second-platform candidate), emulators, and store targets
(`oka_play`, `oka_huawei`) would each add switch cases and Android-specific
code to the core CLI — hardcoding platforms into the layer that must stay
platform-agnostic. Meanwhile the project composition root (`tool/oka_pipeline.dart`)
is already a program oka loads and evaluates (ADR-0010), so oka can *ask the
project what it can do* instead of guessing in a switch.

## Decision

Chosen: **split the CLI into two axes — static verbs and discovered
targets — with a hard law: verbs never know platforms.**

| | Verbs | Targets |
|---|---|---|
| Owner | oka core | project composition root (+ target packages) |
| Nature | static, stable, agent-contract | dynamic, discovered, project-declared |
| Examples | `build`, `explain`, `doctor`, `compare`, `debug step`, `clean`, `cache`, `get` | `device`, `publish-play`, `publish-huawei`, custom flows |

1. **`oka_core` gains a `Target` contract**: a typed, const-constructible
   value that compiles to a `Pipeline` (steps, artifacts, validation — the
   full ADR-0002 machinery). Targets are *not* arbitrary
   `(List<String>) -> Future` functions; keeping them values is what
   preserves `oka explain`, composition-time validation, and the
   no-execution-before-plan law.
2. **The composition root lists targets declaratively**:
   `Oka(pipelines: [...], targets: [DeviceTarget(...), PlayPublishTarget(...)])`.
   Target *implementations* ship in platform/target packages
   (`oka_android` ships `DeviceTarget`; `oka_play`/`oka_huawei` per
   ADR-0013/0014) — the core CLI never grows for a new platform or store.
3. **One new verb: `oka run <target>`.** Dispatch order: core verbs resolve
   first (reserved names; targets cannot shadow them); an unknown verb loads
   the entrypoint (same path `oka build` already uses) and either dispatches
   to a matching target or fails naming the available targets.
4. **`oka explain --targets`** lists each discovered target's step chain —
   the same validated-plan surface as builds.
5. **Top-level `oka --help` stays static** (core verbs + a pointer to
   `oka explain --targets`). Loading user code to print help is slow and
   surprising.
6. **Latency:** entrypoint evaluation for unknown-verb dispatch is
   snapshot-cached, keyed on entrypoint content hash (snapshot
   infrastructure already exists for the global install).
7. **Fold existing violations behind the boundary**: `launch` becomes an
   alias of `oka run device` (device target shipped by `oka_android`); the
   Android nouns of `get` route through ADR-0013 tool providers; `debug dex`
   moves behind the Android package. Verb implementations in `bin/` and
   `packages/oka/lib/src/cli/` contain no platform logic.

## Alternatives considered

- **Keep growing the switch** — rejected: it hardcodes platforms into the
  CLI, the exact failure mode this ADR prevents. Test: after this ADR,
  adding Huawei publishing must not change a single line in `bin/`.
- **Fully dynamic command functions** (`Oka(commands: {'foo': myFn})`) —
  rejected: forks the CLI into "oka verbs" vs "whatever the project hacked
  up", breaks the explain/validation contract, and makes `oka --help`
  non-comparable across projects. Agents lose the stable surface. (Melos
  scripts / cargo custom subcommands are this degenerate version.)
- **No change; convention over mechanism** — rejected: the leak already
  happened (`launch`, `debug dex`); conventions don't survive growth.

## Consequences

Good:
- The core CLI stops growing; platforms and stores arrive as target
  packages over the same kernel (completes the ADR-0013 two-axis model on
  the CLI surface).
- Projects and agents compose custom flows (device loops, publish runs,
  test harnesses) as typed values — discoverable, explainable, validatable.
- Stable agent contract: core verbs are comparable across all projects.

Bad / Neutral:
- New quasi-public `Target` API in `oka_core` → semver discipline.
- Two-step dispatch (verb → target) to document; `oka run` vs direct verbs
  needs a clear help/drive story.
- Snapshot cache adds an invalidation surface (content-hash keyed; worst
  case is a recompile, never staleness).

## Phased plan

Tracked in `docs/PHASE_CHECKLIST.md` (C0–C2). C0/C1 are gated on nothing;
C2's explain integration builds on C0. ADR-0014 (distribution targets)
defines the first non-trivial targets.

**Authoritative source:** `bin/oka.dart`, `packages/oka/lib/src/cli/`,
`packages/oka_core` (Target contract), this ADR,
`docs/PHASE_CHECKLIST.md` (progress).
