# 0002 — Composable build pipeline (steps + YAML overrides + Dart composition)

- **Status:** accepted
- **Date:** 2026-08-24
- **Decision-makers:** Anton, oka agent

## Context

`FlutterApkBuilder.build()` is a monolithic orchestrator: pipeline stages
(assemble → engine extract → codegen → dependency resolve → aapt2/javac/d8 →
package → sign) are hardcoded in one method with a fixed AndroidX dependency
list and hardcoded tool flags. Real-device validation showed the cost: four
consecutive `NoClassDefFoundError` crashes required editing oka's source to fix
the dependency set. Users cannot extend dependencies, flags, or steps without
forking oka.

## Considered options

- **A. Pipeline-as-composition** — extract stages into composable step classes;
  YAML fast-settings for common overrides; optional Dart entrypoint for full
  composition.
- **B. YAML-only hooks** — keep monolith, add `extra_deps` / `pre_build` /
  `post_build`. Not composable; cannot reorder or replace steps.
- **C. Full plugin registry + event bus** — most powerful, too much machinery
  for current needs.

## Decision

Chosen option: **A, staged**, because it fixes the extensibility pain at the
root while preserving ADR-0001's no-Gradle default path unchanged.

1. Extract pipeline stages into `lib/src/pipeline/steps/*.dart`; each step
   implements `Future<StepResult> run(BuildContext)`.
2. Default pipeline composes the same steps in the same order as today's
   `FlutterApkBuilder.build()` — behavior-preserving refactor first.
3. `oka.yaml` gains a `pipeline:` section for per-step fast-settings
   (`extra_deps`, tool flag overrides) without writing Dart.
4. Optional `oka.pipeline.dart` project entrypoint for full Dart composition.
5. Dependency resolution becomes extensible and gains missing-dependency
   recovery: unresolved classes map to Maven coordinates via cached POM /
   maven-index search, surfaced as `oka get <artifact>` suggestions.

Option C's registry/event machinery is deferred until a concrete need appears.

## Consequences

Good:
- Users close dependency gaps without patching oka
- Steps testable in isolation; pipeline visible as data
- Directly addresses the whack-a-mole runtime crash class

Bad / Neutral:
- New quasi-public API surface (`BuildContext`, `StepResult`, `BuildStep`)
  needs semver discipline
- Two config layers (YAML ⊂ Dart) require documented precedence:
  defaults < `oka.yaml` < `oka.pipeline.dart`

**Authoritative source:** `lib/src/pipeline/`, `docs/decisions/0002-*.md`
