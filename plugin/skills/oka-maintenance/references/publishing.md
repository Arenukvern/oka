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
- `dart tool/release/train.dart list` is the dependency order. Never publish
  out of order: a package whose hosted dependency closure does not exist at
  the new version cannot resolve for consumers after upload.
- `oka_dart_kernel`, `oka_update`, and the root `oka_workspace` are
  `publish_to: none`; they ride along but never upload.

## Automated publish (canonical path)

1. Green baseline: `just lint`, `just test`, `just check-contracts`.
2. Ensure every package on the train has pub.dev **automated publishing**
   configured (see the config section below). A package cannot be configured
   before its first publish — first publish manually, then configure.
3. Push the release tag: `git tag v<VERSION> && git push origin v<VERSION>`.
   `pub_publish.yml` triggers on `v*` tags and publishes the whole train via
   GitHub OIDC — no pub.dev credentials live in CI.
4. The train script skips packages whose `<VERSION>` already exists on
   pub.dev (`already exists; skipping`), so re-running after a partial
   failure is safe and idempotent.

### Workflow rules that bite

- The publish step is gated `if: github.event_name == 'push'`. A
  `workflow_dispatch` run **validates the train but publishes nothing**. To
  redo a tag release, re-run the original run (`gh run rerun <run-id>`), which
  keeps its push event — do not dispatch.
- The final "Verify published packages from a fresh hosted consumer" step
  races pub.dev's index propagation (uploads claim "up to 10 minutes"). If it
  fails with `doesn't match any versions` right after a green publish step,
  the uploads succeeded: wait for propagation, then
  `gh run rerun <run-id> --failed` to turn the run green without re-uploading.

## Manual publish (fallback and first-publish)

For a package that has never been on pub.dev, or when CI is unavailable:

```bash
dart tool/release/train.dart list   # order
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

## pub.dev automated-publishing configuration

Per package, at `https://pub.dev/packages/<name>/admin` → Automated
publishing → GitHub Actions:

- Repository: `<owner>/<repo>` (e.g. `Arenukvern/oka`); tag pattern stays
  `v{{version}}`.
- Events: `push` and `workflow_dispatch` (the workflow declares both).
- No required GitHub environment — the workflow declares none.

Operational rules:

- The config endpoint is rate-limited: rapid successive updates across many
  packages return HTTP 429. Pace the updates (~1/minute) and retry the
  rejected one after waiting.
- Configuration persists per package and survives releases; it only needs
  attention when a package is new or the repository/workflow changes.

## Release hygiene

- Never bypass a failing gate; fix the source. Version-skew and changelog
  gates exist to keep the train atomic.
- Store-bound publishing (`oka_play`, `oka_huawei`, `oka_rustore`) is a
  separate concern from pub.dev publishing; see
  `docs/guides/accounts_and_stores.mdx`.
