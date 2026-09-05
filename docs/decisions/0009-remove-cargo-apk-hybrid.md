# 0009 — Remove the demoted cargo-apk hybrid completely

- **Status:** accepted
- **Date:** 2026-09-05
- **Decision-makers:** Anton
- **Completes:** 0001 (no-Gradle default build path; demote cargo-apk hybrid)
- **Executed:** 2026-09-05 — removal applied, `dart test` fully green

## Context

ADR-0001 demoted the cargo-apk + Rust NativeActivity hybrid to experimental;
it has never been un-demoted. Today's inventory:

| Piece | State |
|---|---|
| `rust_wrapper/` (24 KB, NativeActivity crate) | Header comment says "demoted; unused by default oka builds". Links `#[link(name = "flutter_engine")]` against a static library oka never ships — it cannot produce a working artifact as-is. Nothing in `bin/`, `lib/`, or `packages/` reads it. |
| `test/cargo_apk_manifest_test.dart` (quarantine test) | The **only** consumer of `rust_wrapper/` — and the repo's known-failing baseline: it shells out to `cargo metadata`, failing on every machine without a working cargo toolchain, including `ci.yml` (`ubuntu-latest`, no rust setup step). |
| `CargoApkManifest` (`oka_android/src/build/cargo_apk_manifest.dart`) | Exported from the barrel, called by tests only. No production path. |
| `CargoApkConfig` (`oka_core/src/config/cargo_apk_config.dart`) + `OkaConfig.cargoApk` | Exported from the barrel; the getter has **zero callers** in `bin/`/`lib/`/`packages/`. Dead config surface (a `cargo_apk:` section still sits in `example/oka.yaml`). |
| `FlutterAndroidBuilder` | A compatibility wrapper whose sole job is to *refuse* the cargo path and delegate to `FlutterApkBuilder` (asserted by a source-contract test). |

Everything else matching "rust" in the repo is **RuStore** (vendor repo
routing, gradle fixtures, `STORE=rustore` defines) — unrelated, stays.

## Options

- **A. Keep as-is.** Cost: permanently failing test (local + CI), quarantine
  guardrails in `AGENTS.md` for a file nobody writes, dead public API surface
  in semver-covered barrels (ADR-0006), "≤1 failure" baseline caveat in every
  test claim. Benefit: none identified — the experiment cannot link against a
  shipped engine and has sat untouched since demotion.
- **B. Keep the crate, drop only the failing test.** Half-measure: the dead
  API surface and guardrails remain; `rust_wrapper/` still implies an option
  that does not exist.
- **C. Remove completely.** Git history preserves the experiment; resurrecting
  it later is `git revert` + a new ADR. Aligns the codebase with ADR-0001's
  actual state: one build path, no hybrid.

## Decision (accepted)

Option **C** — remove (executed 2026-09-05):

1. `rust_wrapper/` (entire directory)
2. `test/cargo_apk_manifest_test.dart` (the failing quarantine test)
3. `oka_android/src/build/cargo_apk_manifest.dart` + barrel export
4. `oka_core/src/config/cargo_apk_config.dart` + barrel export +
   `OkaConfig.cargoApk` getter
5. `FlutterAndroidBuilder` wrapper + its source-contract test (the delegation
   it guards is the only behavior left; `oka build` already routes to
   `FlutterApkBuilder` directly)
6. `example/oka.yaml`: drop the dead `cargo_apk:` section
7. Docs: ADR-0001 gains a "completed by 0009" note; `why_this_repo_matters.md`,
   `design_faq.md`, `contribution_guide.md`, `AGENTS.md` non-negotiables update

Not in scope: the legacy `--native-android` pure-SDK pipeline (no cargo; its
fate is a separate question), RuStore vendor routing.

## Consequences

Good: `dart test` becomes fully green (baseline "151 pass / ≤1 rust_wrapper
failure" → all pass), CI stops failing, ~600 lines of dead code/config/docs
guardrails gone, barrels match reality.

Bad / Neutral: breaking change for the (theoretical) hook author importing
`CargoApkConfig`/`CargoApkManifest` — acceptable pre-1.0 (0.1.6) and the
surface was already unusable; NativeActivity experiments would need a fresh
ADR + new engine-linking design regardless.

**Verification after execution:** `dart test` 100% green with no baseline
caveat; `grep -ri cargo` over `bin/ lib/ packages/*/lib` returns only this
ADR and history docs; `oka explain` on `example/` unchanged.
