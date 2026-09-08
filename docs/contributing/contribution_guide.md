---
title: Contribution guide
---

# Contributing

Thanks for your interest in oka! The project is agent-first: agents execute,
humans steer. That shapes how contributions work.

## Setup

```bash
git clone https://github.com/Arenukvern/oka.git && cd oka
just install    # dart pub get
just test       # dart test
just lint       # dart analyze
```

## Ground rules

1. **Non-negotiables** (see `AGENTS.md`):
   - The default build path must never shell out to `flutter build apk` /
     Gradle as success.
   - Only the no-Gradle pipeline exists; no cargo/Gradle fallbacks (ADR-0009).
2. **Behavior SSOT is code + tests.** Docs link to implementation; they never
   paraphrase it.
3. **Design forks need an ADR first.** If your change settles a trade-off,
   open/propose an ADR in `docs/decisions/` before coding.
4. **Phases are done only with evidence.** Update
   [`docs/PHASE_CHECKLIST.md`](../PHASE_CHECKLIST.md) with test references.

## Docs sync

After any behavior change, update the matching doc layer — see
[`docs/start_here/docs_map.md`](../start_here/docs_map.md):

| Change type | Update |
|---|---|
| Internal trade-off / architecture | `docs/guides/design_faq.md` Q&A and/or new ADR |
| Public API / usage / config key | `docs/guides/build_and_config.md` (copy-paste valid) |
| Settled strategic decision | `docs/decisions/NNNN-*.md` + index row |
| Phase-level completion | `docs/PHASE_CHECKLIST.md` evidence table |

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/) so
[release-please](https://github.com/googleapis/release-please) can build the
changelog and version bumps:

- `feat:` — new capability (minor bump)
- `fix:` — bug fix (patch bump)
- `docs:` — documentation (patch bump when it is the only change in a release)
- `perf:` — performance improvement
- `chore:` / `refactor:` / `test:` — hidden in the generated changelog

## Releases

Releases are automated on `main` via **release-please**:

1. Merge PRs to `main` with conventional commit titles.
2. release-please opens or updates a **Release PR** (e.g.
   `chore: release 0.1.7`) with `CHANGELOG.md` and `VERSION`.
   [`.github/workflows/release_pr_sync_versions.yml`](../../.github/workflows/release_pr_sync_versions.yml)
   derives `pubspec.yaml`, plugin manifests, and the marketplace catalog from
   that one version and commits any drift.
3. Review the Release PR, run `just check-contracts`, then merge it.
4. release-please creates the `vX.Y.Z` tag and GitHub release **with changelog
   notes**.
5. [`.github/workflows/pub_publish.yml`](../../.github/workflows/pub_publish.yml)
   runs on the tag: asserts tag == `VERSION`, per-package dry-run preflight,
   then publishes to pub.dev **in dependency order**: `oka_core` →
   `oka_android` → `oka` (the split packages share the release train's
   version; `oka_android` declares a hosted `oka_core` constraint, so the
   first train must publish core before android/root). Host projects that
   need the packages before their first release bootstrap with
   `dependency_overrides` (see the build guide).

Manual fallback (when automation is blocked):

```bash
bash tool/release/sync_version.sh --version 0.1.7   # or: just sync-version
# edit CHANGELOG.md, bump .release-please-manifest.json
just check-contracts
git commit -am "chore: release 0.1.7" && git tag v0.1.7 && git push --tags
```

## Contract gates

Run before every merge (`just check-contracts`):

| Gate | Checks |
|---|---|
| `check_version_sync.sh` | VERSION == pubspec == plugin manifests == marketplace |
| `check_docs_drift.sh` | Invariants documented; fast-settings keys present; docs.json sidebar resolves |
| `check_no_personal_paths.sh` | No `/Users/<maintainer>/` paths in tracked files |
| `check_changelog_markdown.sh` | MD052 disable header kept; no bare `[bracket]` identifiers |

## Pull requests

- Keep changes minimal and focused; match existing style.
- Add/adjust tests for anything that changes packaging or pipeline behavior.
- Run `just lint && just test && just check-contracts` before pushing.
