# Publishing `oka_process` on the pub.dev train

`oka_process` is published with the rest of the oka package train by GitHub
Actions (`tool/release/publish_packages.sh` via `.github/workflows/pub_publish.yml`).
It is **first** in `dart tool/release/train.dart list --publish` (no in-train
hosted dependents).

Version and changelog follow the shared release train (`VERSION`, release-please
`extra-files`, `check-contracts` changelog/license gates).

## Before the first automated upload

1. On [pub.dev package admin](https://pub.dev/packages/oka_process/admin), enable
   **Automated publishing** → GitHub Actions:
   - Repository: `Arenukvern/oka`
   - Tag pattern: `v{{version}}`
   - Publishing from GitHub Actions and workflow_dispatch: enabled
2. Without that OIDC grant, the publish job fails with **403** when it reaches
   `oka_process` (even if other train packages already uploaded).

The last release published to pub.dev by hand was **0.8.1**. Train versions
0.9.x–0.10.x were version-synced in-repo only until this package joined the CI
train; the next tagged release is the first automated pub.dev upload at the
current `VERSION`.

## Local preflight (does not publish)

```bash
cd packages/oka_process
dart analyze --fatal-infos
dart test
dart pub publish --dry-run   # expect 0 warnings
```

Full train dry-run from the repo root: `just publish-dry-run` or
`bash tool/release/publish_packages.sh --dry-run`.

Manual recovery when CI is blocked: see
`skills/oka-maintenance/references/publishing.md` (workflow_dispatch on the
release tag).