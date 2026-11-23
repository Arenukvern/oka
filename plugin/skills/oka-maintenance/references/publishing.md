# Publishing to pub.dev

Runbook for cutting and publishing the oka package train. Behavior SSOT is
code (ADR 0054): `.changesets/*.md` intent files (bump declarations),
`.github/workflows/dart_changesets.yml` (assembles the version PR on main
pushes), `.github/workflows/dart_changesets_publish.yml` (per-tag OIDC
publish), and `tool/ci/check_package_consumer.sh` (post-publish consumer
gate). This file records the release procedure and the operational rules
that are easy to get wrong; when a script and this file disagree, fix this
file or the script.

## Train invariants

- **Per-package versions** on the train; dependents' caret constraints are
  rewritten by dart_changesets when a bump requires it.
  `just check-contracts` gates changelogs, licenses, docs drift, workspace
  leaks, and train-inventory SSOT.
- `dart tool/release/train.dart list --publish` is the pub.dev upload order
  (17 packages at time of writing; topological sort of in-train deps with
  `tool/release/train_inventory.dart` as tiebreak). Never publish out of order.
- `oka_dart_kernel`, `oka_devices`, `oka_verify`, and the root workspace
  package are `publish_to: none`; they ride along but never upload. For
  `oka_process` one-time pub.dev automated-publishing setup, see
  `packages/oka_process/PUBLISHING.md`.

## One-time setup (Anton checklist)

Complete once per train package (and again when adding a new publishable
package).

### pub.dev — Automated publishing

For each package below, open `https://pub.dev/packages/<name>/admin` →
**Automated publishing** → GitHub Actions:

| Package |
| --- |
| `oka_process` |
| `resource_composition` |
| `oka_artifacts` |
| `oka_core` |
| `oka_supervisor` |
| `oka_conformance` |
| `oka_android` |
| `oka_google_play` |
| `oka_app_gallery` |
| `oka_huawei` |
| `oka_rustore` |
| `oka_web` |
| `oka_desktop` |
| `oka_service` |
| `oka_harness` |
| `oka_update` |
| `oka` |

Per package:

- **Repository:** `Arenukvern/oka`
- **Tag pattern:** `<package>-v{{version}}` (per-package tags — not a single `vX.Y.Z`)
- **Publishing from GitHub Actions:** enabled
- **Publishing from workflow_dispatch:** enabled
- No required GitHub environment — the workflow declares none.

The config endpoint is rate-limited (~1 update/minute across packages). Retry
after HTTP 429.

A package cannot be configured before its first publish — first publish
manually, then configure automated publishing.

### GitHub — repository settings

Under **Settings → Actions → General**:

- **Workflow permissions:** Read and write permissions (needed for dart_changesets
  to open the version PR and push tags).
- **Allow GitHub Actions to create and approve pull requests:** enabled.

`RELEASE_PLEASE_TOKEN` is still used as a PAT for tag pushes that must trigger
downstream workflows; pub.dev publish uses OIDC on the publish workflow.

## Automated publish (canonical path)

1. Green baseline: `just lint`, `just test`, `just check-contracts`.
2. Complete the one-time setup above for every train package.
3. Add `.changesets/<name>.md` with the intended bump(s); merge to `main`.
4. Review and merge the **version PR** opened/updated by
   `.github/workflows/dart_changesets.yml`.
5. Per-package tags dispatch `.github/workflows/dart_changesets_publish.yml`;
   upload order follows `dart tool/release/train.dart list --publish`.

### Workflow rules that bite

- Publish runs are **per tag** (`<package>-v<version>`), not one consolidated
  root tag (ADR-0054).
- PR validation: CI runs `dart pub publish --dry-run` where applicable; merging
  does not publish without a merged version PR + tags.
- The post-publish consumer gate (`tool/ci/check_package_consumer.sh`) races
  pub.dev index propagation. If it fails immediately after green uploads, wait
  and rerun the failed job — do not re-upload.

## Manual publish (fallback and first-publish)

For a package that has never been on pub.dev, or when CI is unavailable:

```bash
dart tool/release/train.dart list --publish   # order
cd packages/<name> && dart pub publish --dry-run   # 0 warnings expected
dart pub publish --force
```

- Publish in train order and stop at the first failure.
- After a manual publish, wait for propagation before anything resolves
  against the new version.

## Release hygiene

- Never bypass a failing gate; fix the source. Changelog and workspace-leak
  gates exist to keep the train coherent.
- Store-bound publishing (`oka_google_play`, `oka_huawei`, `oka_rustore`) is a
  separate concern from pub.dev publishing; see
  `docs/guides/accounts_and_stores.mdx`.