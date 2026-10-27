# Publishing to pub.dev

Runbook for cutting and publishing the oka package train. Behavior SSOT is code:
`tool/release/publish_packages.sh` (train driver), `tool/release/train.dart`
(order), `.github/workflows/pub_publish.yml` (automation), and
`tool/ci/check_package_consumer.sh` (post-publish consumer gate). This file
records the release procedure and the operational rules that are easy to get
wrong; when a script and this file disagree, fix this file or the script.

## Train invariants

- One workspace `VERSION`; every publishable package's `pubspec.yaml` and
  changelog must match it. `just check-contracts` gates the full sync
  (version, release-please manifest, changelogs, licenses, docs drift).
- `dart tool/release/train.dart list --publish` is the pub.dev upload order.
  Never publish out of order: a package whose hosted dependency closure does
  not exist at the new version cannot resolve for consumers after upload.
- `oka_process` is **manual-only** (`pubDevManualOnly` in `train.dart`); see
  `packages/oka_process/PUBLISHING.md`. `oka_dart_kernel`, `oka_update`, and
  the root `oka_workspace` are `publish_to: none`; they ride along but never
  upload.

## One-time setup (Anton checklist)

Complete once per train package (and again when adding a new publishable
package). `oka_process` is excluded — it is not on the CI train.

### pub.dev — Automated publishing

For each package below, open `https://pub.dev/packages/<name>/admin` →
**Automated publishing** → GitHub Actions:

| Package |
| --- |
| `resource_composition` |
| `oka_artifacts` |
| `oka_core` |
| `oka_supervisor` |
| `oka_conformance` |
| `oka_android` |
| `oka_huawei` |
| `oka_play` |
| `oka_rustore` |
| `oka_web` |
| `oka_harness` |
| `oka` |

Per package:

- **Repository:** `Arenukvern/oka`
- **Tag pattern:** `v{{version}}`
- **Publishing from GitHub Actions:** enabled
- **Publishing from workflow_dispatch:** enabled
- No required GitHub environment — the workflow declares none.

The config endpoint is rate-limited (~1 update/minute across packages). Retry
after HTTP 429.

A package cannot be configured before its first publish — first publish
manually, then configure automated publishing.

### GitHub — repository settings

Under **Settings → Actions → General**:

- **Workflow permissions:** Read and write permissions (needed for release-please
  to dispatch `pub_publish.yml` after a release).
- **Allow GitHub Actions to create and approve pull requests:** enabled
  (release-please Release PRs).

Optional: set `RELEASE_PLEASE_TOKEN` to a PAT or GitHub App token if you need
release-please tag pushes to trigger *other* workflows; pub.dev publish does
not depend on tag-push triggers.

## Automated publish (canonical path)

1. Green baseline: `just lint`, `just test`, `just check-contracts`.
2. Complete the one-time setup above for every train package.
3. Merge the release-please **Release PR** on `main`. release-please creates
   the `vX.Y.Z` tag and GitHub release, then dispatches
   `pub_publish.yml` on that tag ref.
4. The train script skips packages whose `<VERSION>` already exists on
   pub.dev (`already exists; skipping`), so re-running after a partial
   failure is safe and idempotent.

### Workflow rules that bite

- `pub_publish.yml` is **workflow_dispatch only** (no `on.push.tags`). Tag
  pushes from `GITHUB_TOKEN` do not trigger workflows; dispatch is the sole
  publish path.
- To publish or recover manually:
  `gh workflow run pub_publish.yml --ref vX.Y.Z`
- PR validation: CI `validate` job runs per-package `dart pub publish --dry-run`
  on pull requests; merging does not publish.
- The final "Verify published packages from a fresh hosted consumer" step
  races pub.dev's index propagation (uploads claim "up to 10 minutes"). If it
  fails with `doesn't match any versions` right after a green publish step,
  the uploads succeeded: wait for propagation, then
  `gh run rerun <run-id> --failed` to turn the run green without re-uploading.

## Manual publish (fallback and first-publish)

For a package that has never been on pub.dev, or when CI is unavailable:

```bash
dart tool/release/train.dart list --publish   # order
cd packages/<name> && dart pub publish --dry-run   # 0 warnings expected
dart pub publish --force
```

- Publish in train order and stop at the first failure. Local uploader
  credentials on the release machine are used; no login flow is expected.
- A brand-new package must be published together with its hosted dependency
  closure at the current `VERSION` (e.g. a new package depending on
  `oka_core: ^0.7.0` requires `oka_core 0.7.0` uploaded first — the train
  order already encodes this).
- After a manual publish, wait for propagation before anything resolves
  against the new version; the pub.dev API (`/api/packages/<name>`) is the
  cheapest freshness check.

## Release hygiene

- Never bypass a failing gate; fix the source. Version-skew and changelog
  gates exist to keep the train atomic.
- Store-bound publishing (`oka_play`, `oka_huawei`, `oka_rustore`) is a
  separate concern from pub.dev publishing; see
  `docs/guides/accounts_and_stores.mdx`.
