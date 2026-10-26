# Publishing `oka_process` to pub.dev (manual)

This package is **not** published by GitHub Actions or `tool/release/publish_packages.sh`.
The maintainer publishes it from a **macOS** machine after merge.

**Why:** native helper binaries, manual pub.dev publisher approval, and a
different cadence than the main oka train while P0/P1 backends land.

Version stays on the oka release train (`VERSION`, release-please
`extra-files`, `check-contracts` changelog/license gates).

## After merge (macOS)

```bash
git clone https://github.com/arenukvern/oka.git
cd oka
git checkout main   # or the release tag containing this package
dart pub get --no-example
cd packages/oka_process
dart analyze --fatal-infos
dart test
dart pub publish --dry-run   # expect 0 warnings
dart pub login               # once; Google account with pub.dev publisher rights
dart pub publish             # confirm when prompted
```

Use `dart pub publish --force` only if you intend to overwrite a broken upload
(pub.dev policy still applies).

Do **not** run `tool/release/publish_packages.sh --publish` for this package;
it skips `oka_process` by design.
