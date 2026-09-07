# 0014 — Distribution targets and the three-tier secrets model

- **Status:** accepted
- **Date:** 2026-09-06
- **Decision-makers:** Anton, oka agent
- **Depends on:** ADR-0013 (two-axis model, ArtifactStore, T0/T1 landed),
  ADR-0015 (verb/target split, `oka run` landed)

## Context

ADR-0013 fixed the axis — store targets are build-variant compositions plus
publish tails, shipped as packages (`oka_play`, `oka_huawei`, …) — and
deferred the design of the target contract and credential handling. The
maintainer decision on credentials: support Flutter-native mechanisms
(`String.fromEnvironment`, `--dart-define`, `--dart-define-from-file`) and
the asset pattern (paths to secret files) rather than inventing an oka
secret store.

## Critical analysis of the Flutter patterns

The three mechanisms are *not interchangeable*; each belongs to exactly one
tier. Treating them as one bag of options is how secrets end up in binaries.

**`String.fromEnvironment` / `--dart-define` / `--dart-define-from-file`
(compilation-time constants)**
- Mechanics: values are resolved by the compiler and **baked into the
  binary** (Dart AOT snapshot). They are recoverable from `libapp.so` by
  snapshot analysis; they appear in CI logs, in `flutter run --verbose`, and
  in process listings (`ps` shows the full flag list).
- Therefore: correct for **app-visible, non-secret build config** — API base
  URLs, feature flags, build channel names, flavor identity. They are
  compile-time `const`, tree-shakeable, and type-checkable at the use site.
- Therefore: **wrong for credential contents.** A service-account private
  key in a dart-define is in the artifact you ship, in every log that echoed
  the command, and on every machine that ran the build.
- Also: they cannot express file indirection at compile time — the value is
  fixed before the app runs, so "the app reads a secret at runtime" is
  simply a different problem (that is runtime configuration, e.g.
  `--asset-bundle` payloads or a backend fetch, and out of scope here).

**Paths to secret files (the asset pattern)**
- Store-publishing credentials are **build-host credentials**, not
  app-embedded ones: the Play Publisher API service-account JSON, the
  AppGallery Connect API credentials, keystores. They are consumed by oka
  steps (`apksigner`, upload clients) on the machine running the build —
  the app binary never needs them.
- The right shape is the same as assets: typed config holds a **path** (or
  an env-var name resolving to a path); the file itself stays out of git
  (`gitignore`-gated) and out of the binary. This matches the existing
  `signing_config.dart` (keystore path + password indirection).

## Decision

### 1. PublishTarget contract (oka_core)

A `PublishTarget` is a `Target` (ADR-0015: typed, const-constructible,
compiles to a validated pipeline) with additional conformance laws:

- **Dry-run without credentials must succeed** and print exactly what a real
  run would do (upload endpoint, track, artifact, metadata) — the ADR-0008
  plan law applied to publishing.
- **No stdin, ever** (ADR-0013 law).
- **No secret values in `PipelineState`, logs, or events** — paths and
  resolved booleans only. State can be dumped by tooling; treat it as
  public.
- Publish tails compose the platform build's artifacts via the standard
  artifact mechanism (e.g. requires `Artifact<String>('aab-path')`).

### 2. Three-tier secrets model

| Tier | Mechanism | Contents | Resolved by | Example |
|---|---|---|---|---|
| App build config | `String.fromEnvironment` via `--dart-define` / `--dart-define-from-file` | non-secrets only | compiler, into the binary | `API_BASE_URL`, feature flags, channel name |
| Build-host credentials | **path references** (asset pattern) | secret files | oka pipeline at build time | Play service-account JSON, keystore, agconnect creds |
| CI indirection | env vars naming **paths** (not values) | — | oka resolution policy | `OKA_PLAY_SERVICE_ACCOUNT` |

Resolution policy for credential paths reuses the T1 ordered-policy shape
(inspectable as data, printed by doctor): explicit typed-config path →
`OKA_<TARGET>_*` env var → well-known location (`~/.oka/credentials/<target>/…`).
Failures name every candidate tried and the fix — same remediation law as
tool resolution.

### 3. Guards (oka enforces the model)

- **Doctor secret audit:** dart-define keys (inline or from file) are
  checked against secret-ish key patterns (`password`, `token`, `secret`,
  `apikey`, `private_key`, …). A hit is a **failure** naming the tier rule:
  move the value to a credential file and reference the path.
- **Repo hygiene:** a credential file resolved inside the project must be
  gitignored — oka checks and warns (leveraging the existing
  check-contracts machinery where applicable).
- **Define passthrough:** `--dart-define` / `--dart-define-from-file` flow
  through `okaRun` into `flutter assemble` unchanged (Flutter-native, no oka
  re-typing beyond the audit); typed config may reference the same keys for
  compile-time-constant consumption in build steps.

### 4. Package layout

`oka_play`, `oka_huawei`, … are target packages per ADR-0013: each ships its
`PublishTarget` + upload steps + credential resolution entries. GMS-exclusion
variants are compositions of the Android build config, validated at
composition time by the artifact checker. Conformance tests (dry-run, no
stdin, no secrets in state) live in a shared suite any target must pass —
mirroring the `universal_storage_conformance` pattern.

## Alternatives considered

- **Dart-defines for everything (single mechanism)** — rejected: bakes
  secrets into shipped binaries and CI logs (analysis above).
- **Oka-owned secret store / vault integration** — rejected: invents a
  credential manager; users already have one (env, CI secret managers,
  keychains). Oka references paths; storage stays external.
- **Runtime secret fetch (app queries a backend at startup)** — a valid app
  architecture but orthogonal: it removes secrets from the binary without
  oka involvement. Publish credentials are build-host-side and unaffected.

## Consequences

Good:
- Flutter-native paths for everything the app genuinely needs embedded
  (`fromEnvironment` stays first-class); no new secret format.
- Store credentials never enter the artifact, git history, logs, or state.
- Credential resolution is inspectable data (doctor), testable with
  injected env, and dry-runnable without credentials — agents can operate
  publishing end-to-end without ever touching a real secret.

Bad / Neutral:
- Two mechanisms to explain (defines vs credential paths) — the doctor
  audit makes the boundary mechanical, not tribal knowledge.
- Path-based credentials shift storage responsibility to the user/CI —
  documented per-target setup; conformance suite keeps targets honest.

## Phased plan

Tracked in `docs/PHASE_CHECKLIST.md` (P0–P2). P0 unblocks package work;
`oka_play` (P1) before `oka_huawei` (P2) — Play is the reference target.

**Authoritative source:** this ADR, `packages/oka_core` (PublishTarget,
credential policy), `docs/PHASE_CHECKLIST.md` (progress).
