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
- Mark a phase done only when its tests/evidence exist (`docs/PHASE_CHECKLIST.mdx`).
- Design forks → decision checkpoint + ADR before coding (see `docs/decisions/`).

## Map — "I want to…"

| I want to… | Read |
|---|---|
| Understand what oka owns / boundaries | `docs/start_here/why_this_repo_matters.mdx` |
| Review the proposed whole-application composition direction | `docs/decisions/0030-application-composition-and-operation-projections.mdx` (proposed; current boundaries remain binding) |
| Review the proposed store-free patch/update direction | `docs/decisions/0031-declarative-patch-units.mdx` (proposed; web-first evidence in `docs/evidence/deferred-patch-units-spike-2026-10-01.mdx`) |
| Review the proposed kernel-graph/bundler direction | `docs/decisions/0032-oka-dart-kernel-graph-ownership.mdx` (proposed; `packages/oka_dart_kernel` + `packages/oka_update`; harness manual in `skills/oka-kernel`) |
| Know what stands between the update API and production | `docs/decisions/0034-update-api-production-ladder.mdx` (proposed; gap analysis + P0–P5 ladder) |
| Design the patch-shipping journey or server live patching | `docs/decisions/0035-live-update-journey-and-server-patching.mdx` (proposed; Dart-first authoring, server lanes, `oka ship`) |
| Decide shell vs harness vs declared verbs for live-update automation | `docs/decisions/0036-live-update-agent-surface.mdx` (accepted, implemented: gates = thin shell, orchestration = Dart drivers, `oka.live.*` verbs in `oka_update/live_agent.dart`) |
| Run a rebuild-and-swap artifact lane (OTA exes, generated bundles) from file saves | `docs/decisions/0038-command-lanes-on-the-live-watcher.mdx` (accepted, implemented: optional spec `commands` section in `oka_live_watch`, commands-only boots need no toolchain; first consumer: the harness OptMem deploy) |
| Ship store-free patches invisibly / run the air channel | `docs/decisions/0037-air-channel-invisible-patches.mdx` (accepted, implemented: `oka ship` derives everything from the working tree incl. snapshot-from-build; `UpdateClient`/`planChain` resolve chains vs snapshots; signed channels; gates G-AC1..8 done, G-AC9 ADR-gated) |
| Know **why** a design choice was made | `docs/guides/design_faq.mdx`, `docs/decisions/` |
| Know **how** to run/build/test | `docs/guides/build_and_config.mdx`, `docs/start_here/quick_recipes.mdx` |
| Run/understand live update (first steps → JIT dev loop → AOT production, dangers) | `docs/guides/live_update.mdx` |
| Dev session with watch-on-save + r/R on macOS/web (`oka dev` = `oka run dev`; android daemon = `oka dev android`) | `docs/guides/live_update.mdx` → "The converged session"; gate: `packages/oka_dart_kernel/tool/gate_run_dev.sh` |
| Inspect or clean storage across projects, devices and sessions | `docs/guides/cache_storage.mdx`, ADRs 0019–0021; `oka cache schema`, `oka session-state`; `StorageInventory`, `CacheDiagnostics` and `CacheProjectRegistry` in `oka_core` |
| Migrate an existing Gradle app | `docs/guides/gradle_migration.mdx` (works / needs config / unsupported + verification loop) |
| Set up multiple store accounts / white-label brands / ship to stores | `docs/guides/accounts_and_stores.mdx` (per-account targets, per-brand pipelines via `--flavor`, credential layout) |
| Check phase status & evidence | `docs/PHASE_CHECKLIST.mdx` |
| Verify a release actually starts (or diagnose a startup hang) | `oka run verify` (ADR-0029); `oka why <step>` for step-cache staleness |
| Prove live patching on running apps across platforms | `packages/oka_dart_kernel/tool/gate_live_e2e.sh`; session API in `packages/oka_update/lib/src/live/` (ADR-0031 gate 6, ADR-0032 gate 10) |
| Prove the air-channel arcs (engine VM lane, web static-host lane) | `packages/oka_dart_kernel/tool/gate_air_channel.sh`, `gate_air_web.sh` (ADR-0037 G-AC7) |
| Live-patch a real product family (oka CLI itself, an MCP stdio server, a Flutter desktop app) | `packages/oka_dart_kernel/tool/gate_live_products.sh` — per-family wire facts in `skills/oka-kernel/references/troubleshooting.md` (ADR-0035 §2e) |
| Endless dev loop / AOT revision slots | `packages/oka_dart_kernel/tool/gate_endless_loop.sh` (last_answer, patch continue + reset) and `gate_aot_slots.sh` (in-process AOT slot flip) — ADR-0035 |
| Browse the docs site | `docs/` (published via docs.page) |
| See CLI commands | `packages/oka/bin/oka.dart`, `packages/oka/lib/src/cli/` |
| Understand/extend the build pipeline | `packages/oka_android/lib/src/pipeline/`; shared contracts in `packages/oka_core/lib/src/pipeline/` — see ADR 0002 |
| Add a dependency / fix missing-class crashes | Build guide → Dependencies Station; table in `packages/oka_android/lib/src/build/dependency_suggest.dart` |
| Local .aar files / AAR natives & res | Build guide → Assets & Icon Station (`local_aars`); `extractAarPayload` in `dependency_cache.dart` |
| Compose a custom pipeline in Dart | `example/tool/oka_pipeline.dart`; contracts in `packages/oka_core/lib/src/pipeline/pipeline.dart` |
| Review responsibility boundaries or refactor a large file | `docs/guides/capability_architecture.mdx`, ADR 0022; `plugin/skills/oka-maintenance/references/architecture.md`; `steward action inspect oka.check.architecture --json` |
| Icons, deeplinks, extra assets config | Build guide → Assets & Icon Station |
| Enable hot reload / dev loop (`oka dev`) | `docs/decisions/0011-hot-reload-run-loop.mdx`, `docs/guides/hot_reload_plan.mdx` |
| Launch/declare browser sessions (Chrome, WebMCP flags) for testing | `docs/decisions/0017-browser-session-targets.mdx`, `packages/oka_web/lib/src/session/` |
| Understand/extend spawned-process and managed session-state lifecycle (leases, teardown, cleanup) | `docs/guides/process_lifecycle.mdx` (working manual); ADRs: `docs/decisions/0018-process-lifecycle-leases.mdx`, `docs/decisions/0025-managed-session-state-providers.mdx` |
| Govern daemons/watchers/models/schedules declaratively (supervisor: declare desired, converge, budgeted restarts, cession-based kill rights) | `docs/guides/supervisor.mdx` (60-second version + roadmap); ADRs: `docs/decisions/0040-declarative-supervisor.mdx` (accepted, R1 shipped: `packages/oka_supervisor` — `Supervisor.converge`, pure planner, advisory `MachineRegistry` under `~/.oka/supervisor/`), `docs/decisions/0041-supervisor-adoption-ladder.mdx` (accepted, L0 shipped: `SpecCodec` plan JSON, `SpecStore`, status projection, `oka supervisor status\|apply\|check`), `docs/decisions/0042-resident-supervisor-ota-runtime-owner.mdx` (proposed, gated) |
| Cut a release / version sync | `docs/contributing/contribution_guide.mdx` → Releases; bundled skill `oka-maintenance` |
| Install agent skills | `npx skills add Arenukvern/oka --skill oka-maintenance` |

## Skill Steward

Implement repository stewardship tooling in Dart. Shell scripts may remain as
thin entry points; do not introduce Python runtime dependencies for these tools.

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
