# resource_composition

Declarative resource composition contracts (oka ADR-0026): typed immutable
component graphs, validated and explained **before any side effect**;
first-class readiness declarations with budgets; typed output promises
(`OutputRef<T>`) between components; lifecycle events with terminal causes;
and a `ResourceProvider` seam with declared capabilities. Zero package
dependencies, vendor-neutral by design (consumers must not import oka).

Design laws:

- Compose small const values by constructor injection; never mutate a
  graph by string key.
- `validate()` / `explain()` are pure — providers are never contacted.
- An unready component never satisfies a `dependsOn` edge; on readiness
  timeout the runner cancels the start and awaits it (never
  `Future.timeout` over a live child), then tears down in reverse order,
  never masking the original failure.
- Probe mechanics, protocol semantics, and stop ladders stay in providers;
  oka's `oka_core` process seam (tree-aware stop, bounded runs, identity)
  is the reference adapter.
- Death carries a terminal cause (`exited`, `signaled`, `killedOnDeadline`,
  `providerFault`, `transportLost`, `unknown`); `unknown` is never silently
  upgraded — report-never-guess.

See `docs/decisions/0026-declarative-resource-composition-sdk.mdx`,
`docs/guides/resource_composition_plan.mdx`, and the R0 survey evidence in
`docs/evidence/process-lifecycle-r0-survey-2026-09-27.mdx`.
