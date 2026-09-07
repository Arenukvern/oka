---
title: Publishing to Google Play & Huawei AppGallery
---

# Publishing guide

End-to-end setup for distributing an oka-built app: Google Play and Huawei
AppGallery Connect. The why (targets are not platforms, the secrets model)
lives in [ADR-0014](../decisions/0014-distribution-targets-secrets-model.md);
the CLI surface law (verbs never know targets) in
[ADR-0015](../decisions/0015-cli-verb-target-split.md). Behavior SSOT is the
package code: [`packages/oka_play`](https://github.com/Arenukvern/oka/tree/main/packages/oka_play)
and [`packages/oka_huawei`](https://github.com/Arenukvern/oka/tree/main/packages/oka_huawei).

## How publishing works in oka

A publish target is a **project-declared value** in your composition root
(`tool/oka_pipeline.dart`) — never a CLI flag, never a plugin (ADR-0015).
It composes two things:

1. a **build-variant composition** of your Android app (for Huawei: the
   GMS-excluding variant, validated at composition time), and
2. a **publish tail** (upload steps) that consumes the AAB artifact.

```dart
// tool/oka_pipeline.dart
Oka(
  pipelines: [/* your AndroidPipeline as usual */],
  targets: [
    PlayPublishTarget(dryRun: true),                        // oka run publish-play
    HuaweiPublishTarget(dryRun: true, release: /* … */),    // oka run publish-huawei
  ],
)
```

`oka run <target>` compiles the target into a validated pipeline — the same
explain-before-execute machinery as builds. List what the project declares:

```bash
oka explain --targets
oka run publish-play            # dry-run plan by default
```

Two laws are enforced by a shared conformance suite
([`oka_conformance`](https://github.com/Arenukvern/oka/tree/main/packages/oka_conformance)):

- **Dry-run without credentials succeeds.** Every target is dry-run by
  default and the plan names the endpoint, track, artifact, and metadata —
  zero HTTP, no secret needed. Agents can rehearse a publish end-to-end.
- **No secret values in state, logs, events, or plans.** Only redacting
  path references (`CredentialRef`) exist beyond the upload step's local
  scope; a dump can never leak a credential.

## The tier rule (ADR-0014) — where values may live

| Tier | Mechanism | May hold | Resolved by | Example |
|---|---|---|---|---|
| App build config | `--dart-define` / `--dart-define-from-file` (`String.fromEnvironment`) | **non-secrets only** | compiler, baked into the binary | `API_BASE_URL`, feature flags, channel name |
| Build-host credentials | **path references** (asset pattern) | secret files | oka pipeline at build time | Play service-account JSON, AGC API-client JSON, keystores |
| CI indirection | env vars naming **paths** (never values) | — | oka credential policy | `OKA_PLAY_SERVICE_ACCOUNT_JSON` |

`oka doctor` audits dart-define keys against secret-ish patterns
(`password`, `token`, `secret`, `apikey`, `private_key`, …) — a hit is a
**failure** naming the tier rule: move the value into a credential file and
reference its path. A credential file resolved inside the project must be
gitignored.

## Google Play, end to end

### One-time console setup

1. **Play Console**: create the app, then *Users and permissions → invite a
   service account*.
2. **Google Cloud Console**: create a service account, enable the **Google
   Play Android Developer API**, and create a JSON key.
3. Grant the service account a release role on the app (e.g. *Release to
   testing tracks* for internal/alpha; *Release to production* for
   production).

### Files & resolution order

The service-account JSON is a **build-host credential** — a path, never a
value (tier 2). `PlayPublishTarget` resolves it through the ordered policy:

| Precedence | Source | Example |
|---|---|---|
| 1 | typed config (`serviceAccountPath`) | `credentials/play-sa.json` |
| 2 | env var naming a path | `OKA_PLAY_SERVICE_ACCOUNT_JSON=/path/play-sa.json` |
| 3 | well-known location | `~/.oka/credentials/play/service-account-json` |

The JSON must be a `service_account` object with `type`, `client_id`,
`client_email`, `private_key` (shape-checked by name only — values are never
echoed). Missing path → the failure names every candidate tried and the fix.

### Declare & run

```dart
// tool/oka_pipeline.dart — targets:
PlayPublishTarget(
  dryRun: true,                       // default — plan, never upload
  packageName: 'dev.example.app',     // must match the Play Console app
  releaseTrack: PlayTrack.internal,   // internal | alpha | beta | production
  // userFraction: 0.1,               // staged rollout (status: inProgress)
  // releaseName: '1.2.0',
  // serviceAccountPath: 'credentials/play-sa.json',  // tier-2 path
),

// 1. build the artifact (same pipeline the target's tail composes):
oka build aab --release --verify-aab
// 2. rehearse — prints the plan: endpoint, track, artifact, metadata:
oka run publish-play
// 3. ship — flip dryRun: false in the typed config:
oka run publish-play
```

A real run executes the Play Publisher API **Edits flow**
(androidpublisher/v3): create edit → upload AAB → assign track → commit.
The uploaded version code comes back from the bundle.

## Huawei AppGallery, end to end

Huawei is a **build variant + publish tail** (ADR-0013/0014): the same app
built **without GMS dependencies** — `HuaweiBuildVariant` filters GMS
coordinates out of `extraDeps` and gives GMS artifacts typed ids
(`gms-dep:<coordinate>`), so a step requiring one fails validation at
composition time, before any tool runs.

### One-time console setup

1. **AppGallery Connect**: create the app (note the numeric **app id**) and
   set up the release channel (`beta` = open testing, or `production`).
2. *Users and permissions → API client*: create the API-client credential
   and download its JSON (`client_id` + `client_secret`).

### Files & resolution order

| Precedence | Source | Example |
|---|---|---|
| 1 | typed config (`credentialPath`) | `credentials/agc-client.json` |
| 2 | env var naming a path | `OKA_HUAWEI_AGCONNECT_CREDENTIALS=/path/agc-client.json` |
| 3 | well-known location | `~/.oka/credentials/huawei/agconnect-credentials` |

### Declare & run

```dart
// tool/oka_pipeline.dart — targets:
HuaweiPublishTarget(
  dryRun: true,                     // default — plan, never upload
  release: HuaweiReleaseConfig(
    appId: '110012345',             // numeric AGC app id (not a secret)
    track: HuaweiReleaseConfig.defaultTrack,   // 'beta' or 'production'
    // phasePercent: 100,           // staged rollout %
    // releaseNotes: [AgcReleaseNote(language: 'en', file: 'whatsnew-en.txt')],
  ),
  // credentialPath: 'credentials/agc-client.json',  // tier-2 path
),
```

Release notes are **file paths** (language → project-relative file), never
inlined content — the tier rule again. A real run executes the AGC REST
flow over `https://connect-api.cloud.huawei.com`: OAuth token fetch →
upload-url → artifact upload → `app-submit`.

```bash
oka build aab --release --verify-aab
oka run publish-huawei           # dry-run plan by default
# flip dryRun: false when ready
```

## Failure playbook

| Symptom | Meaning & fix |
|---|---|
| `CredentialRef … → [redacted]` resolution failure listing candidates | The credential path didn't resolve. Fix any one source: set `serviceAccountPath` / `credentialPath`, export the env var **to a path**, or place the file at the well-known location. A configured-but-missing path fails without falling through. |
| `invalid service-account JSON: missing required field(s) …` | Wrong JSON shape (Play). Re-download the key; it must be `type: service_account` with `client_id`, `client_email`, `private_key`. |
| AGC credential format failure naming `"client_id"` / `"client_secret"` | Wrong JSON shape (Huawei). Re-export the AGC API-client credential file. |
| `packageName is empty` / config validation issues | The target validates typed config **before any HTTP**. Fill in `packageName` (Play) or `appId` (Huawei). |
| `userFraction must be strictly between 0 and 1` | Staged-rollout fraction out of range (Play). |
| Upload step fails: publish artifact missing | Build first: `oka build aab --release`. An explicit `artifactPath` override points where the AAB actually lives (default: `.oka_cache/build/release/aab/app-release.aab`). |
| Doctor flags a secret-ish dart-define key | Tier rule: move the value into a credential file and reference the path — defines are baked into the shipped binary. |
| HTTP failures (401/403) | Play: check the service account's grant in Play Console & that the API is enabled. Huawei: re-export the API-client credential; check the app id. |

Dry-run diagnostics print every credential candidate tried with printable
sources (`env OKA_…`, well-known path) — an agent can act from the message
alone.

## Composing custom targets

A custom store/target is a `PublishTarget` (oka_core): typed,
const-constructible, compiled to a validated pipeline via
`publishSteps`/`uploadStep`, with `name`, `endpoint`, `track`,
`artifactId`, `credentialRefs`, and `metadata` feeding the dry-run plan.
The three conformance laws are mechanical: reuse
[`oka_conformance`](https://github.com/Arenukvern/oka/tree/main/packages/oka_conformance)
(`expectPublishConformance`, `expectPlanShape`, `expectNoSecretMaterial`,
`FakeHttpTransport`) in the target's tests, exactly as `oka_play` and
`oka_huawei` do. New target packages start as an RFC-style proposal against
the conformance suite — the suite is the contract, the CLI never grows.
