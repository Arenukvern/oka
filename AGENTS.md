# AGENTS.md — oka

Oka is a Dart CLI that replaces Gradle for Flutter Android builds
(`flutter assemble` + direct Android SDK tools). Agents execute; humans steer.
This file is a **map**, not a manual — follow links.

## Non-negotiables

- Default build path must **never** shell out to `flutter build apk` / Gradle as success (Phase 0 invariant).
- Never mutate/corrupt shared `rust_wrapper/Cargo.toml`; the Rust hybrid is quarantined/demoted.
- Mark a phase done only when its tests/evidence exist (`docs/PHASE_CHECKLIST.md`).
- Design forks → decision checkpoint + ADR before coding (see `docs/decisions/`).

## Map — "I want to…"

| I want to… | Read |
|---|---|
| Understand what oka owns / boundaries | `docs/NORTH_STAR.md` |
| Know **why** a design choice was made | `DESIGN_FAQ.md`, `docs/decisions/` |
| Know **how** to run/build/test | `DX_FAQ.md` |
| Check phase status & evidence | `docs/PHASE_CHECKLIST.md` |
| See CLI commands | `bin/oka.dart`, `lib/src/cli/` |
| Understand the build pipeline | `lib/src/build/` (+ tests in `test/`) |

## Commands

```bash
make install   # dart pub get
make test      # dart test
make lint      # dart analyze
make global    # reinstall global oka (clears snapshot cache)
```

Behavior SSOT is code + tests. Docs link; they never paraphrase implementation.
