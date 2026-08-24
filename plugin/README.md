# oka (plugin)

Single source of truth for the shippable oka plugin: **Claude Code**,
**Codex**, and **Cursor** marketplace layouts plus bundled agent skills.

## What this plugin ships

- **Skills** — `skills/oka-maintenance/`: the golden path for changing oka's
  pipeline/build code, docs sync rules, device validation, and the release
  train.
- **Agent manifests** — `.claude-plugin/`, `.codex-plugin/`,
  `.cursor-plugin/` plugin.json files, version-pinned to root `VERSION`.

## Install

```bash
# Skills only (open ecosystem — any agent):
npx skills add Arenukvern/oka --skill oka-maintenance

# Claude Code git marketplace:
/plugin marketplace add Arenukvern/oka
/plugin install oka@Arenukvern-oka

# Codex git marketplace:
codex plugin marketplace add Arenukvern/oka
```

The CLI itself installs from pub.dev: `dart pub global activate oka`.

## Versioning

All manifests carry the repo version. release-please bumps them via
`release-please-config.json` `extra-files`; `tool/release/sync_version.sh`
derives everything from root `VERSION`. Run `make check-contracts` before
merge — it fails on drift.
