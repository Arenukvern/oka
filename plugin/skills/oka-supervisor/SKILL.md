---
name: oka-supervisor
description: >-
  Govern long-lived processes declaratively with Oka's supervisor: author
  plans (services, jobs, watch/interval triggers), run `oka supervisor
  status|apply|check`, consume records and the status projection, or add an
  observe-only bridge for another repo. Use when daemons, MCP servers,
  watchers, models or schedules die silently, when wiring a new consumer
  repo, or when extending the supervisor itself.
license: MIT
metadata:
  version: 1.0.0
  author: Arenukvern
compatibility:
  - dart
  - flutter
---

# Oka supervisor

Declare what should run; `converge` makes reality match once and exits.
ADRs: [0040](https://github.com/Arenukvern/oka/blob/main/docs/decisions/0040-declarative-supervisor.mdx)
(engine) · [0041](https://github.com/Arenukvern/oka/blob/main/docs/decisions/0041-supervisor-adoption-ladder.mdx)
(adoption ladder) · [0042](https://github.com/Arenukvern/oka/blob/main/docs/decisions/0042-resident-supervisor-ota-runtime-owner.mdx)
(resident, proposed). Guide: `docs/guides/supervisor.mdx`.

## The verbs

| Want | Do |
|---|---|
| See one project's state | `oka supervisor status --json` |
| Make reality match a plan once | `oka supervisor apply plan.json [--dry-run]` |
| CI drift gate (read-only) | `oka supervisor check plan.json --json` |
| Author in Dart | `DesiredState(specs: [ComponentSpec(...)])` + `Supervisor.converge` |
| Author for apps/git/CLI | `SpecCodec().decode(json)` — plan schema v1, round-trip law |
| Read like an app does | `projectStatus` / `statusJson` — one projection everywhere |

## The five laws (memorize, skip the rest)

1. **Converge is explicit** — observe → diff → act once → exit. No daemon.
2. **Restarts are budgeted** — `maxRestarts` per window, then `giveUp`;
   reset = revision bump, never implicit.
3. **Kill rights = spawn lineage or cession** — `killPolicy: none`
   records are findings, never targets.
4. **The registry is advisory** — evidence, never authority.
5. **One fact envelope** — findings are `supervisorFinding` events in the
   substrate JSONL.

Plus one (ADR-0041): **one ladder, two artifacts** — plan JSON + record
JSON everywhere; a rung changes transport and authority, never schema.

## Adding a consumer (the bridge pattern)

New self-contained tool dir in the consumer repo, path deps on
`oka_supervisor` + `oka_core` + `resource_composition`; an
**observe-only provider** whose `start` throws; `converge(apply: false)`.
Never spawn, never signal — findings only. Landed examples:
`ecsai_harness/tool/supervisor_beat`, `dart_flutter_packages/tool/supervisor_composition`,
and the read-only codemap lanes projection in `packages/oka_supervisor/tool/`.

## Where to look

- Runnable demo: `cd packages/oka_supervisor && dart run example/supervise_demo.dart`
- Working manual: `docs/guides/supervisor.mdx` (60-second version + roadmap)
- Package source: `packages/oka_supervisor/lib/src/` (spec, planner,
  registry, converge, codec, spec_store, status, codemap_projection)
- Ladder + gates: ADR-0041; resident/OTA: ADR-0042 (proposed — do not
  implement until its entry criteria hold)
