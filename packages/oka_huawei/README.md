# oka_huawei

The Huawei AppGallery Connect distribution target for
[oka](https://github.com/Arenukvern/oka) — ADR-0014 P2.

Distribution targets are **not** platforms (ADR-0013's two-axis law): a
store target is a build-variant composition plus a publish tail, composed
over the standard `oka_core`/`oka_android` contracts. This package ships
exactly that for Huawei AppGallery:

* **`HuaweiPublishTarget`** — a `PublishTarget` (typed, compiles to a
  validated pipeline). With `dryRun: true` (the default) it produces a
  `PublishPlan` describing exactly what a real run would do — endpoint,
  track, artifact, metadata — and issues **no HTTP**. With `dryRun: false`
  the upload tail runs the AppGallery Connect REST flow:
  token fetch → upload-url → artifact upload → submit.
* **`HuaweiBuildVariant`** — the GMS-excluding `AndroidBuild` composition:
  GMS-provided Maven coordinates (Play Services, Billing, Ads, Firebase)
  are filtered out of `extraDeps`, and GMS-provided artifacts get typed
  ids (`gms-dep:<coordinate>`). A step requiring one fails the **existing**
  artifact validator at composition time — before any tool runs.
* **`AgcClient`** — the REST flow over an injectable `http.Client`
  (tests use a scripted fake transport; no real network, ever).
* **`HuaweiReleaseConfig`** — typed release metadata (track, staged-rollout
  percent, release-note *file paths* per language).

## The three-tier secrets model (ADR-0014)

Credentials are **path references**, never values:

* the API-client credential file (`client_id` / `client_secret`) resolves
  through the `huawei/agconnect-credentials` `CredentialRef` policy:
  explicit typed-config path → `OKA_HUAWEI_AGCONNECT_CREDENTIALS` env var
  (a *path*) → `~/.oka/credentials/huawei/agconnect-credentials`;
* file contents live only inside the upload step's local scope — never in
  `PipelineState`, logs, events, or plans (all types redact on dump);
* release notes are file paths too; contents are read at publish time.

## Conformance

`HuaweiPublishTarget` passes the shared ADR-0014 publishing conformance
suite (`oka_conformance`): dry-run without credentials, no stdin, no secret
values in state — plus offline scripted-transport tests for the real flow
and composition-validation tests proving the GMS-exclusion law.

## Status

P2 of the ADR-0014 phased plan — see `docs/PHASE_CHECKLIST.md`. Real
uploads against production AGC remain gated on maintainer credentials.
