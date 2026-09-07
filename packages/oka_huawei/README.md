# oka_huawei

Huawei AppGallery Connect distribution target for
[oka](https://github.com/Arenukvern/oka) — the no-Gradle Flutter Android
build system. `HuaweiPublishTarget` composes the AppGallery Connect REST
upload tail (token fetch → upload-url → artifact upload → submit) onto a
**GMS-excluding Android build variant**, as one typed value in your
existing `Oka(...)` composition root. No CLI changes, no Gradle, no
oka.yaml.

A store target is **not** a platform (ADR-0013 two-axis law): it is a
build-variant composition plus a publish tail. The same app, same
pipeline code — composed once *without* Google Play Services for
AppGallery, and (with [oka_play](../oka_play)) once *with* everything for
Google Play.

**Dry-run by default.** Until you explicitly set `dryRun: false`, the
target compiles to a plan step that prints exactly what a real run would
do — and issues zero HTTP, needs no credentials, and needs no AAB on disk.

## 30-second quickstart

This is a complete `tool/oka_pipeline.dart` (ADR-0010 — the project *is*
the config). The same file ships, analyzed, as
[`example/oka_pipeline_example.dart`](example/oka_pipeline_example.dart):

```dart
import 'package:oka_android/oka_android.dart';
import 'package:oka_huawei/oka_huawei.dart';

/// The GMS-excluding build variant: GMS coordinates (Play Services,
/// Billing, Ads, Firebase) are dropped from extraDeps, and a step
/// *requiring* a GMS-provided artifact fails validation before any tool
/// runs.
const HuaweiBuildVariant variant = HuaweiBuildVariant(
  android: AndroidBuild(packageName: 'dev.example.app'),
  overrides: PipelineOverrides(
    extraDeps: [
      'androidx.core:core-ktx:1.13.1',              // kept (not GMS)
      'com.android.billingclient:billing-ktx:7.0.0', // excluded (GMS)
    ],
  ),
);

Future<void> main(final List<String> args) => okaRun(
      args,
      oka: Oka(
        pipelines: [
          AndroidPipeline(
            config: variant.android,
            overrides: variant.gmsFreeOverrides,
          ),
        ],
        targets: [
          // ONE target: dry-run today; flip dryRun: false to upload.
          const HuaweiPublishTarget(
            release: HuaweiReleaseConfig(
              appId: '110012345', // AGC console → My apps (not a secret)
              releaseNotes: [
                // Notes are FILE PATHS (tier rule) — never inlined text.
                AgcReleaseNote(language: 'en', file: 'whatsnew-en.txt'),
              ],
            ),
            // Dry-run is the default (law 1). To upload for real, flip:
            //
            // dryRun: false,
            // credentialPath: 'credentials/agconnect.json', // PATH only
          ),
        ],
      ),
    );
```

Then:

```bash
oka explain --targets     # validated step chains, nothing executes
oka run publish-huawei    # dry-run: prints the plan, zero HTTP
```

The dry run prints the publish plan (this rendering is asserted verbatim by
this package's tests, so it cannot drift from reality):

```text
📋 Publish plan for "publish-huawei":
  target: publish-huawei (dry run — nothing was uploaded)
  endpoint: AppGallery Connect Publishing API (https://connect-api.cloud.huawei.com)
  track: beta
  artifact: aab-path → build/aab/app-release.aab
  metadata.appId: 110012345
  metadata.phasePercent: 100
  credential: CredentialRef(huawei/agconnect-credentials → [redacted])
```

When the plan looks right, flip `dryRun: false` (and provide the
credential — below), run `oka build aab`, then `oka run publish-huawei`
again: the same chain runs the real AGC upload tail — OAuth2
client-credentials token → upload-url → AAB upload → app-submit.

## Credential setup (one-time, numbered)

The credential is an AppGallery Connect **API client** (OAuth2
`client_id` / `client_secret`). It is referenced by *path* and consumed on
the machine that builds — never committed, never embedded, never logged
(ADR-0014 three-tier model).

1. In AppGallery Connect → **My apps**, note the numeric **app id** of
   your app (this one is not a secret — it appears in the plan).
2. In AppGallery Connect → **Users and permissions** → **API client**,
   create an API client and note the generated `client_id` and
   `client_secret`.
3. Store them as the API-client credential JSON file the upload step
   parses (shape checked; values never echoed):
   ```json
   {
     "client_id": "123456",
     "client_secret": "<your-secret>"
   }
   ```
4. Put the file somewhere on the build host, in one of the three policy
   tiers (tried in order, first hit wins):
   - **Tier 1 — typed config:** `credentialPath:` in the target value (a
     missing configured path fails *without* falling through);
   - **Tier 2 — environment:** `OKA_HUAWEI_AGCONNECT_CREDENTIALS`, set to
     a **path** (never the file contents);
   - **Tier 3 — well-known location:**
     `~/.oka/credentials/huawei/agconnect-credentials`.
5. If the file lives inside a repo, gitignore it. Only the *path* ever
   enters oka state, logs, or plans — credential refs, the parsed
   credential object, and the OAuth token all render redacted.
6. Release notes are paths too: `AgcReleaseNote(language: 'en',
   file: 'whatsnew-en.txt')` — the file is read at publish time and its
   content never enters typed config or state.
7. **Dry-run first:** `oka run publish-huawei` with `dryRun: true` (the
   default) needs no credential at all and issues zero HTTP. Only flip
   `dryRun: false` when the plan is exactly what you want.

## What happens on failure

Failures are step failures (non-zero exit) whose messages name the
candidates tried and the fix — never any secret material:

| You see | Why | Fix |
|---|---|---|
| `Credential "huawei/agconnect-credentials" not found.` + `Tried (in order): …` + `Fix: …` | No file at any tier you configured | Place the file at the well-known location, set `OKA_HUAWEI_AGCONNECT_CREDENTIALS` to a path, or set `credentialPath` |
| `Credential "huawei/agconnect-credentials" not found.` + `Tried (in order): 1. config … path in typed config` + `Fix: …` | Tier 1 path configured but the file is absent — oka never silently falls through from an explicit path | Fix the path in the typed config |
| `agconnect credentials file must contain non-empty "client_id" and "client_secret" …` | Wrong file or truncated export | Re-create the API client in AGC and re-export |
| `the publish artifact does not exist: <path> — build the AAB first` | A *real* run needs the bundle | `oka build aab` (or set `artifactPath`) |
| `release note file for "en" not found: …` | A configured note file is missing | Create it, or drop the language from the typed config |
| `AGC submit failed (HTTP 401, ret.code …)` | API client revoked/rotated, wrong scope | Re-issue the API client; the token is fetched fresh every run, so simply re-run after fixing |
| Composition-time: a step requires `gms-dep:<coordinate>` | GMS-dependent step in a GMS-free variant | Remove the step or the dependency — validation fails before any tool runs |

## FAQ

**Is my API-client secret safe in the repo?**
No — never commit it. ADR-0014's tier rule keeps values out of typed
config, `oka.yaml`, git, state, logs, and plans: oka handles the *path*,
consumes the file on the build host, and every secret-bearing type
(credential ref, parsed credential, OAuth token) redacts unconditionally.

**Does dry-run cost anything or hit the network?**
No. Dry-run compiles to `[huawei-stage-aab, publish-plan]` and issues zero
HTTP — proven in tests with a canary transport that throws on any request.
It needs no credentials and no AAB on disk.

**Can I publish without Gradle on disk?**
Yes — that is the whole point. oka builds AABs with `flutter assemble` +
direct Android SDK tools (no Gradle daemon), and `HuaweiPublishTarget`
composes onto that pipeline. Nothing in this package invokes Gradle.

**How do I test without credentials?**
Run the dry-run target (needs nothing), and use the shared
[oka_conformance](../oka_conformance) suite from your own tests — this
package's conformance is asserted with it, with the real AGC flow tested
offline against a scripted fake transport.

**Does it work with flavors?**
Yes. Flavors are just Dart composition (shared bases, per-flavor typed
config). Declare one `HuaweiPublishTarget` per flavor (target names are
unique) and point `artifactPath` at that flavor's AAB if it lives outside
oka's default `build/aab/` layout. Track, phase percent, and release notes
are per-target typed fields.

**Why did my Play Services / Billing dependency disappear?**
By design. AppGallery artifacts ship without GMS: `HuaweiBuildVariant`
filters GMS coordinates out of `extraDeps` (`excludedGmsDeps` names
exactly what was dropped), and a step *requiring* a GMS-provided artifact
fails composition-time validation — before any tool runs.

## Conformance

`HuaweiPublishTarget` passes the shared ADR-0014 publishing conformance
suite in [oka_conformance](../oka_conformance): dry-run without
credentials, no stdin, no secret values in state — plus offline
scripted-transport tests for the real AGC flow and composition-validation
tests proving the GMS-exclusion law.

See the [docs](https://docs.page/arenukvern/oka) and the
[design decisions](https://github.com/Arenukvern/oka/tree/main/docs/decisions)
(ADR-0013 two-axis model, ADR-0014 targets + secrets model).
