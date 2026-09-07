# oka_play

Google Play publish target for [oka](https://github.com/Arenukvern/oka) —
the no-Gradle Flutter Android build system. `PlayPublishTarget` composes
the Play Publisher API upload tail (Edits flow: create edit → upload AAB →
assign track → commit) onto **any oka Android AAB build**, as one typed
value in your existing `Oka(...)` composition root. No CLI changes, no
Gradle, no oka.yaml.

**Dry-run by default.** Until you explicitly set `dryRun: false`, the
target compiles to a plan step that prints exactly what a real run would
do — and issues zero HTTP, needs no credentials, and needs no AAB on disk.

## 30-second quickstart

This is a complete `tool/oka_pipeline.dart` (ADR-0010 — the project *is*
the config). The same file ships, analyzed, as
[`example/oka_pipeline_example.dart`](example/oka_pipeline_example.dart):

```dart
import 'package:oka_android/oka_android.dart';
import 'package:oka_play/oka_play.dart';

Future<void> main(final List<String> args) => okaRun(
      args,
      oka: const Oka(
        pipelines: [
          // The Android pipeline you already have — oka_play changes
          // nothing about it.
          AndroidPipeline(
            config: AndroidBuild(packageName: 'dev.example.app'),
          ),
        ],
        targets: [
          // ONE target: dry-run today; flip dryRun: false to upload.
          // Target names are unique per project (ADR-0015).
          PlayPublishTarget(
            packageName: 'dev.example.app',
            // Dry-run is the default (law 1). To upload for real, flip:
            //
            // dryRun: false,
            // serviceAccountPath: 'credentials/play-sa.json', // PATH only
            //
            // Optional knobs (all typed, all plan-visible in dry-run):
            // userFraction: 0.10,   // staged rollout (0 < x < 1)
            // releaseName: 'Release 42',
            // artifactPath: 'build/app-release-bundle.aab',
          ),
        ],
      ),
    );
```

Then:

```bash
oka explain --targets     # validated step chains, nothing executes
oka run publish-play      # dry-run: prints the plan, zero HTTP
```

The dry run prints the publish plan (this rendering is asserted verbatim by
this package's tests, so it cannot drift from reality):

```text
📋 Publish plan for "publish-play":
  target: publish-play (dry run — nothing was uploaded)
  endpoint: Google Play Publisher API (androidpublisher/v3)
  track: internal
  artifact: aab-path → build/aab/app-release.aab
  metadata.packageName: dev.example.app
  credential: CredentialRef(play/service-account-json → [redacted])
```

When the plan looks right, flip `dryRun: false` (and provide the
credential — below), run `oka build aab`, then `oka run publish-play`
again: the same chain runs the real upload tail — JWT (RS256) → OAuth
token exchange → Edits API (create edit → upload AAB → assign track →
commit).

## Credential setup (one-time, numbered)

The credential is a **build-host credential**: it is referenced by *path*
and consumed on the machine that builds — never committed, never embedded,
never logged (ADR-0014 three-tier model).

1. In Google Play Console → **Setup → API access**, link a Google Cloud
   project to your developer account.
2. In that Cloud project, create a **service account** and download its
   JSON key file (the file contains `type`, `client_id`, `client_email`,
   `private_key`).
3. Back in Play Console → **Users and permissions**, invite the service
   account and grant it app-level release permission for the apps it
   should publish.
4. Put the JSON file somewhere on the build host, in one of the three
   policy tiers (tried in order, first hit wins):
   - **Tier 1 — typed config:** `serviceAccountPath:` in the target value
     (a missing configured path fails *without* falling through);
   - **Tier 2 — environment:** `OKA_PLAY_SERVICE_ACCOUNT_JSON`, set to a
     **path** (never the JSON contents);
   - **Tier 3 — well-known location:**
     `~/.oka/credentials/play/service-account-json`.
5. If the file lives inside a repo, gitignore it. Only the *path* ever
   enters oka state, logs, or plans — and credential refs render
   redacted (`CredentialRef(play/service-account-json → [redacted])`).
6. **Dry-run first:** `oka run publish-play` with `dryRun: true` (the
   default) needs no credential at all and issues zero HTTP. Only flip
   `dryRun: false` when the plan is exactly what you want.

## What happens on failure

Failures are step failures (non-zero exit) whose messages name the
candidates tried and the fix — never any secret material:

| You see | Why | Fix |
|---|---|---|
| `Credential "play/service-account-json" not found.` + `Tried (in order): …` + `Fix: …` | No file at any tier you configured | Place the file at the well-known location, set `OKA_PLAY_SERVICE_ACCOUNT_JSON` to a path, or set `serviceAccountPath` |
| `Credential "play/service-account-json" not found.` + `Tried (in order): 1. config … path in typed config` + `Fix: …` | Tier 1 path configured but the file is absent — oka never silently falls through from an explicit path | Fix the path in the typed config |
| `invalid service-account JSON: missing required field(s): …` | Downloaded key is truncated/wrong shape | Re-download the JSON key from Google Cloud Console |
| `AAB not found at <path> — build the AAB first` | Dry-run staged a default path, but a *real* run needs the bundle | `oka build aab`, or set `artifactPath` |
| `PlayPublishTarget config is invalid: …` | Empty `packageName`, or `userFraction` outside (0, 1) | Fix the typed config; fails before any HTTP |
| `Play Publisher API error: POST … → HTTP 403 …` | Service account lacks permission, or the app is not linked to it | Re-check Play Console API access + user permissions |

## FAQ

**Is my service account safe in the repo?**
No — never commit it. ADR-0014's tier rule keeps values out of typed
config, `oka.yaml`, git, state, logs, and plans: oka handles the *path*,
consumes the file on the build host, and every credential reference
renders redacted. Put the file outside the repo, or gitignore it.

**Does dry-run cost anything or hit the network?**
No. Dry-run compiles to `[stage-aab, publish-plan]` and issues zero HTTP —
proven in tests with a canary transport that throws on any request. It
needs no credentials and no AAB on disk.

**Can I publish without Gradle on disk?**
Yes — that is the whole point. oka builds AABs with `flutter assemble` +
direct Android SDK tools (no Gradle daemon), and `PlayPublishTarget`
composes onto that pipeline. Nothing in this package invokes Gradle.

**How do I test without credentials?**
Run the dry-run target (needs nothing), and use the shared
[oka_conformance](../oka_conformance) suite from your own tests — this
package's conformance is asserted with it (`dryRun` without credentials,
no stdin, no secret values in state), with the real-run flow tested
offline against a scripted fake transport.

**Does it work with flavors?**
Yes. Flavors are just Dart composition (shared bases, per-flavor typed
config). Declare one `PlayPublishTarget` per flavor — target names must be
unique, so give each a distinguishing composition — and point
`artifactPath` at that flavor's AAB if it lives outside oka's default
`build/aab/` layout. Track, rollout fraction, and release name are
per-target typed fields.

**How do staged rollouts work?**
Set `userFraction` (0 < x < 1): the release is submitted with status
`inProgress` at that fraction. Omit it: the release is `completed` on the
track. Either way the plan shows the value before anything is uploaded.

## Conformance

`PlayPublishTarget` passes the shared ADR-0014 publishing conformance
suite in [oka_conformance](../oka_conformance): dry-run without
credentials, no stdin, no secret values in state — plus offline
scripted-transport tests for the real Edits flow.

See the [docs](https://docs.page/arenukvern/oka) and the
[design decisions](https://github.com/Arenukvern/oka/tree/main/docs/decisions)
(ADR-0014 targets + secrets model, ADR-0015 verb/target split).
