---
title: Evidence — Skill Steward adoption & benchmarks
---

# Evidence — Skill Steward adoption & benchmarks (2026-09-06)

Scope: Skill Steward adoption for the oka repo (archetype `cli_tool`,
modeled on the `mcp_flutter` stewardship pattern) plus the first recorded
benchmark runs. All four contract-gate actions pass; build benchmarks are
recorded for the example project.

## Contract smoke scenario (`oka.contract-status-smoke`)

Run:

```bash
steward benchmark --scenario oka.contract-status-smoke --strict \
  --output .steward/benchmark-summaries/oka.contract-status-smoke.json --json
```

Result: **pass** (4/4 actions, `--strict` durability on committed artifacts).

| Action | Exit | Duration |
|---|---|---|
| `oka.check.version-sync` | 0 | 32ms |
| `oka.check.docs-drift` | 0 | 49ms |
| `oka.check.changelog-markdown` | 0 | 11ms |
| `oka.check.no-personal-paths` | 0 | 747ms |

## Build benchmarks (`oka.bench.build`, example project)

Run: `make bench` → `tool/benchmarks/build_benchmarks.sh example`
(runner: `dart run`, machine-local — see the summary JSON for the
environment block; comparable only against similar setups).

| Benchmark | Wall time |
|---|---|
| `oka explain` (validated plan, zero tools) | **1.18s** |
| `oka build apk` (incremental, warm `.oka_cache`) | **20.41s** |
| `oka compare` (byte-equivalence self-gate) | **1.35s** |
| `oka debug step resolve-abis` (single-step probe) | **2.76s** |

Note: `dart run` adds ~1–2s startup over the global snapshot; the global
runner (`make global`) measures lower.

## Follow-ups

- Run `make bench` before/after dev-loop work (ADR-0011 H-series) to keep
  regressions visible.
- Re-record the smoke benchmark whenever a gate script changes.
