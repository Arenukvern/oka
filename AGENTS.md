# AGENTS.md — oka

Oka is a declarative, compositional, AI-native build system: **one code for
every platform build** — created not because Gradle is slow but because
platform build configs are locked, scattered, and endlessly repeated. It
collapses them into one typed, copyable Dart surface, starting with
**no-Gradle Flutter Android** (`flutter assemble` + direct Android SDK
tools). Agents execute; humans steer. This file is a **map**, not a manual —
follow links.

## Non-negotiables

- Default build path must **never** shell out to `flutter build apk` / Gradle as success (Phase 0 invariant).
- One build path only: the no-Gradle pipeline. The cargo-apk/Rust hybrid was removed (ADR-0009) — do not reintroduce it without a new ADR.
- Mark a phase done only when its tests/evidence exist (`docs/PHASE_CHECKLIST.md`).
- Design forks → decision checkpoint + ADR before coding (see `docs/decisions/`).

## Map — "I want to…"

| I want to… | Read |
|---|---|
| Understand what oka owns / boundaries | `docs/start_here/why_this_repo_matters.md` |
| Know **why** a design choice was made | `docs/guides/design_faq.md`, `docs/decisions/` |
| Know **how** to run/build/test | `docs/guides/build_and_config.md`, `docs/start_here/quick_recipes.md` |
| Check phase status & evidence | `docs/PHASE_CHECKLIST.md` |
| Browse the docs site | `docs/` (published via docs.page) |
| See CLI commands | `bin/oka.dart`, `lib/src/cli/` |
| Understand/extend the build pipeline | `lib/src/pipeline/` (steps in `pipeline/steps/`, tool invocations in `pipeline/toolchain.dart`) — see ADR 0002 |
| Add a dependency / fix missing-class crashes | Build guide → Dependencies Station; table in `lib/src/build/dependency_suggest.dart` |
| Local .aar files / AAR natives & res | Build guide → Assets & Icon Station (`local_aars`); `extractAarPayload` in `dependency_cache.dart` |
| Compose a custom pipeline in Dart | `example/tool/oka_pipeline.dart`; contracts in `lib/src/pipeline/pipeline.dart` |
| Icons, deeplinks, extra assets config | Build guide → Assets & Icon Station |
| Enable hot reload / dev loop (`oka dev`) | `docs/decisions/0011-hot-reload-run-loop.md`, `docs/guides/hot_reload_plan.md` |
| Cut a release / version sync | `docs/contributing/contribution_guide.md` → Releases; bundled skill `oka-maintenance` |
| Install agent skills | `npx skills add Arenukvern/oka --skill oka-maintenance` |

## Skill Steward

Oka is under [Skill Steward](https://github.com/Arenukvern/skill_steward)
stewardship (`steward.yaml`, archetype `cli_tool`). Agent workflow:

1. Start with `steward doctor --json`, then `steward actions list --json`.
2. Inspect any intended action before execution:
   `steward action inspect <id> --json`.
3. Contract smoke scenario (all four release gates):
   `steward benchmark --scenario oka.contract-status-smoke --strict --json`.
4. Build benchmarks: `just bench` (evidence in `.steward/benchmark-summaries`,
   gitignored; summarized in `docs/evidence/`).
5. `steward validate skills/` when touching `skills/`.

## Commands

```bash
just install   # dart pub get
just test      # dart test
just lint      # dart analyze
just global    # reinstall global oka (clears snapshot cache)
just check-contracts   # release gates: version sync, docs drift, changelog hygiene
```

Behavior SSOT is code + tests. Docs link; they never paraphrase implementation.
