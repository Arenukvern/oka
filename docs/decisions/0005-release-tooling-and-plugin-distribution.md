# 0005 — Release tooling: release-please + one-version train; skills via plugin distribution

- **Status:** Accepted
- **Date:** 2026-08-24

## Context

Oka is preparing for OSS publishing. Releases previously meant hand-editing
`pubspec.yaml` and `CHANGELOG.md` with no automation, no tag discipline, and
no way for agents to answer "what changed in vX?" from git alone. Separately,
agent-facing knowledge (the `oka-maintenance` skill) lived only in the
maintainer's global `~/.agents/skills/` — invisible to contributors and not
installable.

Two decisions were needed:

1. Which release/changelog generator fits a single-package Dart CLI.
2. How to distribute agent skills alongside the product.

## Considered options

**Release generator:**

- *Changesets* — explicit intent files; excellent for JS monorepos, alien to
  pub's tag + CHANGELOG culture.
- *Melos* — Dart monorepo versioning; oka is a single package, so Melos adds
  a workspace layer for nothing.
- *release-please* — conventional commits → Release PR → tag, native support
  for syncing extra files (pubspec, JSON manifests) via `extra-files`.

**Skill distribution:**

- *Keep skills in the maintainer's global directory* — zero setup, but not
  discoverable or installable by anyone else.
- *Separate skills repo* — splits product and its procedures across repos.
- *In-repo plugin tree (`plugin/skills/`) + root symlink* — the mcp_flutter
  pattern: one repo ships CLI on pub.dev AND skills via `npx skills add` AND
  Claude/Codex/Cursor marketplaces.

## Decision

Chosen option: **release-please with a one-version train**, and **in-repo
plugin distribution**.

1. release-please on `main` (`release-please-config.json`,
   `.release-please-manifest.json`). Conventional commits drive changelog +
   version. `VERSION` is the single source; `tool/release/sync_version.sh`
   derives `pubspec.yaml`, plugin manifests, and `.claude-plugin/marketplace.json`
   from it. A Release PR workflow auto-commits drift.
2. Tag-triggered `pub_publish.yml`: asserts tag == VERSION, dry-run preflight,
   then `dart publish`.
3. Skills ship in `plugin/skills/oka-maintenance/`; root `skills` symlink makes
   them installable via `npx skills add Arenukvern/oka --skill oka-maintenance`;
   `.claude-plugin/marketplace.json` enables `/plugin marketplace add Arenukvern/oka`.
4. Mechanical gates in `tool/contracts/check_contracts.sh` (version sync, docs
   drift, no personal paths, changelog hygiene), wired into CI and the justfile.

## Consequences

**Good**

- Changelog lives in git; agents can read "what shipped" without GitHub API.
- One version source; drift is mechanically impossible to merge.
- Skills are versioned with the product they describe.

**Bad / trade-offs**

- Conventional commit discipline is now required on every PR title.
- Plugin manifest versions must be bumped by the sync script — adding a new
  manifest means updating three places (config `extra-files`, sync script,
  check script).

## Authoritative sources

- `release-please-config.json`, `.release-please-manifest.json`, `VERSION`
- `tool/release/sync_version.sh`, `tool/release/check_version_sync.sh`
- `tool/contracts/check_contracts.sh`
- `.github/workflows/release-please.yml`, `release_pr_sync_versions.yml`, `pub_publish.yml`
- `plugin/` (skills + agent manifests), `skills` symlink, `skills.sh.json`
