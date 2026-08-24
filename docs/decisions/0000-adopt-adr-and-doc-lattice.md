# 0000 — Adopt ADRs + concept doc lattice

- **Status:** accepted
- **Date:** 2026-08-24

## Context

Oka is agent-executed (`AGENTS.md` as map), but knowledge lived in README prose
and a single phase checklist. Design rationale (why no Gradle, why the Rust
hybrid is demoted) had no durable home, so agents risk re-litigating settled
forks.

## Decision

Adopt a vectorless doc lattice:

- `docs/NORTH_STAR.md` — charter: ownership + boundaries
- `docs/decisions/` — MADR-style ADRs, append-only, this index
- `DESIGN_FAQ.md` / `DX_FAQ.md` — why / how Q&A per FAQ-driven development
- `AGENTS.md` stays a router (~100 lines), never an encyclopedia

Docs link to code; code + tests remain the behavior SSOT.

## Consequences

Design forks require a decision checkpoint + ADR before coding. Docs must not
paraphrase implementation — link with `Authoritative source:` footers.
