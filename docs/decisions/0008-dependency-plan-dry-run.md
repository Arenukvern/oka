# 0008 — Dependency-plan dry-run (`oka explain --deps`)

- **Status:** accepted
- **Date:** 2026-09-05
- **Decision-makers:** Anton, oka agent
- **Extends:** 0007 (self-resolving builds), 0006 (declarative composition)

## Context

`oka explain` / `oka build --dry-run` validate the pipeline composition —
artifact chain, signing, version injection, plugin plan — with zero tool
invocations. But plugin discovery is file-only: Maven coordinates parsed from
plugin gradle files are never resolved at dry-run time. A bad version string,
an unresolvable parent-POM, or a 404 artifact still costs a full build cycle
to surface. The resolver (`MavenResolver`, ADR-0007) already isolates failures
per artifact — but `resolveWithTransitives` swallows them (verbose-only
prints), so nothing upstream can report them.

## Decision

1. **One shared declared-deps collector.** The gradle-parsed, conditionally
   deduplicated root coordinates + plugin repos (`collectDeclaredDeps` on
   `PluginPackager`) are extracted from `packageOne` so the packaging step and
   the dry-run plan see identical inputs. No second parser, no drift.
2. **Resolver reports failures.** `resolveWithTransitives` gains an optional
   `onFailure(coord, error)` callback — the per-artifact isolation stays, but
   failures become observable instead of verbose-only.
3. **`oka explain --deps`** composes the dependency plan from the declared
   inputs (plugins + `pipeline.extra_deps`) and resolves it through
   `DependencyCache`:
   - **cache-only by default** (`allowNetwork: false`): explain stays fast and
     side-effect-free; artifacts missing from the local `~/.oka` cache are
     reported as `⚠️ not in local cache`, not failures.
   - **`--network` opts in** to full resolution (downloads like a build).
     Hard resolution failures (404, unresolvable POM) print `❌` and make
     explain exit 1 — the dry-run becomes a gate, matching the `oka compare`
     philosophy: a claim is a command.
4. **Design law:** no new YAML keys, no stringly maps. The plan is a typed
   value (`DependencyPlanReport` with entries/findings/resolved jars) built
   from the existing resolver service — the same capability as the build's
   `DependencyResolveStep`, composed read-only.

## Consequences

Good: resolution problems are a dry-run finding (seconds) instead of a
mid-build failure (minutes); cache-only default keeps explain offline-safe;
plugin packaging and the plan share one collector so they cannot disagree.

Bad / Neutral: cache-only mode cannot expand POM transitives (metadata fetch
needs network) — the report states this explicitly; `--network` makes network
requests during a "dry-run", so it is opt-in, not default; explain now can
exit non-zero under `--deps --network` (previously it never failed).

**Authoritative source:** `packages/oka_android/lib/src/dependency_plan.dart`,
`packages/oka/lib/src/cli/explain_command.dart`, `packages/oka_android/lib/src/build/
plugin_packager.dart` (`collectDeclaredDeps`), `maven_resolver.dart`
(`onFailure`).
