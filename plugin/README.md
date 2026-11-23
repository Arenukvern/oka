# oka (plugin)

Single source of truth for the shippable oka plugin: **Claude Code**,
**Codex**, and **Cursor** marketplace layouts plus bundled agent skills.

## What this plugin ships

- **Skills** — `skills/oka-maintenance/`: the golden path for changing oka's
  pipeline/build code, docs sync rules, device validation, and the release
  train.
- **Agent manifests** — `.claude-plugin/`, `.codex-plugin/`,
  `.cursor-plugin/` plugin.json files (versioned manually today; not synced to
  the pub train — see ADR-0054).

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

Plugin manifests are **not** auto-synced to per-package pub.dev versions
(ADR-0054). Bump plugin.json when the plugin surface itself changes. The pub
train uses dart_changesets (`.changesets/` → version PR → per-package tags).
Run `just check-contracts` before merge — it fails on docs and changelog drift.