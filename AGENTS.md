# AGENTS.md — oka

Oka is a Dart CLI that replaces Gradle for Flutter Android builds
(`flutter assemble` + direct Android SDK tools). Agents execute; humans steer.
This file is a **map**, not a manual — follow links.

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
| Compose a custom pipeline in Dart | `example/bin/custom_pipeline.dart`; contracts in `lib/src/pipeline/pipeline.dart` |
| Icons, deeplinks, extra assets config | Build guide → Assets & Icon Station |
| Cut a release / version sync | `docs/contributing/contribution_guide.md` → Releases; bundled skill `oka-maintenance` |
| Install agent skills | `npx skills add Arenukvern/oka --skill oka-maintenance` |

## Commands

```bash
make install   # dart pub get
make test      # dart test
make lint      # dart analyze
make global    # reinstall global oka (clears snapshot cache)
make check-contracts   # release gates: version sync, docs drift, changelog hygiene
```

Behavior SSOT is code + tests. Docs link; they never paraphrase implementation.
