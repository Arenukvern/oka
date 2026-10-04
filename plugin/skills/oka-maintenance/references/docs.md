# Docs lattice & gates (oka)

How oka's documentation is wired: layers, gates, and the traps. The SSOT
law holds everywhere: behavior truth is code + tests; docs link, never
paraphrase implementation.

## Layers

| Layer | Files | Audience |
|---|---|---|
| Router | `AGENTS.md` (map table) + root `README.md` | agents / first-time humans |
| Charter | `docs/start_here/why_this_repo_matters.mdx` | why + invariants |
| How-to | `docs/guides/build_and_config.mdx` (manual), `docs/start_here/quick_recipes.mdx` (copy-paste) | users |
| Distribution | `docs/guides/accounts_and_stores.mdx`, `docs/guides/publishing.mdx`, `docs/guides/web_shell_station.mdx` | users shipping |
| Why | `docs/guides/design_faq.mdx`, `docs/decisions/` (ADRs, append-only) | maintainers |
| Status | `docs/PHASE_CHECKLIST.mdx` (+ `docs/archive/` for completed eras) | evidence |
| Ladder | `examples/01..06` (runnable teaching projects) + `example/` (full reference) | learners |

## Hard gate constraints (`tool/contracts/check_docs_drift.dart`)

These tokens/links are load-bearing — a rewrite that drops them fails
`just check-contracts`:

- `docs/guides/build_and_config.mdx` must contain: `extra_deps`,
  `extra_assets`, `deeplinks`, `local_aars`, `icon`.
- `docs/start_here/why_this_repo_matters.mdx` must contain `never`.
- `AGENTS.md` must contain `flutter build apk`.
- `README.md` must contain `docs.page/arenukvern/oka`.
- Every non-http href in `docs.json` `sidebar` must resolve to a file.

## Traps learned the hard way

- **Anchors**: archived docs and ADRs link to guide headers (e.g.
  `#-dev-loop-station-adr-0011`). Keep header text stable when the anchor
  is referenced; compressed content in place instead of renaming sections.
- **`examples/` (plural) is excluded from root `dart analyze`**
  (`analysis_options.yaml`) — the ladder projects are standalone Flutter
  apps and resolve against the wrong package context from the workspace
  root (~87 false errors otherwise). `example/` (singular) is the full
  reference app and is analyzed separately by `flutter analyze`.
- **Release train scope**: `tool/release/train.dart` walks root pubspec +
  `example/pubspec.yaml` + `packages/*` only — `examples/` is invisible to
  version sync; that's intentional.
- **Stale plan-docs**: completed phase plans compress to a status table;
  keep still-live reference sections (wire formats, gotchas) verbatim —
  e.g. `hot_reload_plan.mdx` keeps the delegation-channel wiring.
- **Skills**: canonical skill source is `plugin/skills/` (root `skills/` is
  its symlink — edit one place). Run `steward validate skills/` after any
  skill change.
- **Recognition**: `.all-contributorsrc` + the README table between the
  `ALL-CONTRIBUTORS-LIST` markers; add contributors via
  `npx all-contributors add` and commit both files.

## Docs sync (after behavior changes)

| Change type | Update |
|---|---|
| Internal trade-off / architecture | `docs/guides/design_faq.mdx` and/or new ADR |
| Public API / usage / config key | `docs/guides/build_and_config.mdx` (copy-paste valid) |
| Stores / accounts / distribution | `docs/guides/accounts_and_stores.mdx`, `publishing.mdx` |
| Settled strategic decision | `docs/decisions/NNNN-*.mdx` + index + `AGENTS.md` map row |
| Phase-level completion | `docs/PHASE_CHECKLIST.mdx` evidence; extract plan-docs to `docs/evidence/` |

## Verification

```bash
bash tool/contracts/check_contracts.sh   # version sync + docs drift + paths + changelog
dart analyze                             # root workspace (examples/ excluded)
just test                                # full suite
```
