# 0012 — Remove the embedded AI client; oka is agent-driven, not LLM-embedding

- **Status:** accepted
- **Date:** 2026-09-12
- **Decision-makers:** Anton, oka agent
- **Extends:** 0006 (Dart entrypoint hooks), 0007 (self-resolving builds)
- **Supersedes:** the "AI conversion" section of `docs/guides/design_faq.md`

## Context

oka shipped `lib/src/ai/` — an embedded `OkaAiAgent` (Apple Foundation Models
on macOS, Gemini fallback) that converted legacy `build.gradle` files to
`oka.yaml` during `oka init --yaml`, plus prompt templates for manifest
merging and error explanation. The output types (`ManifestMergeResult`,
`MergeRules`) lived in oka_core's public barrel.

oka's thesis (AGENTS.md) is "Agents execute; humans steer." The primary user
is an AI agent **driving** oka. That changes the calculus for any feature
that embeds an LLM inside the tool.

## Decision

Remove the embedded AI client, prompt templates, and their output types from
the published packages.

1. The driving agent is the LLM. Asking oka to call Gemini with its own API
   key is redundant: the agent invoking `oka init` already has full repo
   context and better tools than frozen prompt templates. Conversion is an
   agent task, not a build-tool task.
2. A build system must be deterministic. Hidden network calls (API keys,
   provider outages, non-deterministic output, `$HOME` prompt caches) inside
   `oka init` violate that.
3. The migration path remains, deterministically: when `oka init` finds a
   legacy `android/app/build.gradle`, it prints precise conversion
   instructions (sections to port, pointer to `oka explain` and
   `dependency_suggest`'s known-class table) so the driving agent or human
   performs the conversion in reviewable diff space.
4. `ManifestMergeResult` / `MergeRules` are removed from oka_core: they were
   the AI merge output type and have no other consumer. Manifest merging
   stays a deterministic, spec-driven step (`manifest_spec.dart`).

## Consequences

- `lib/src/ai/` deleted; `http` and `crypto` dropped from the root package.
- `oka init --yaml` no longer converts Gradle automatically; it instructs.
- Agent workflows are unchanged or improved: `oka explain`, typed
  `oka.yaml`/entrypoint config, and the known-class dependency table give
  the driving agent everything the embedded client approximated.
- Re-introducing any LLM-backed command requires a new ADR with evidence
  that the driving agent cannot perform the task better.
