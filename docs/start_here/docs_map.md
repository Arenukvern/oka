# Docs map

Oka's documentation is layered: behavior SSOT is code + tests; docs link,
never paraphrase implementation.

| Layer | File(s) | Answers |
|---|---|---|
| Charter | [why_this_repo_matters](why_this_repo_matters.md) | What oka owns, invariants, success criteria |
| How-to | [`docs/guides/build_and_config.md`](../guides/build_and_config.md) | Run, build, test, configure, troubleshoot |
| Why | [`docs/guides/design_faq.md`](../guides/design_faq.md) | Design rationale per area |
| Decisions | [`docs/decisions/`](../decisions/index.md) | Settled architecture decisions (ADRs) |
| Status | [`docs/PHASE_CHECKLIST.md`](../PHASE_CHECKLIST.md) | Phase plan + test evidence map |
| Agent map | [`AGENTS.md`](../../AGENTS.md) | Router for agents — start here |

## Reading paths

- **New user** → README → [build guide Setup Hub](../guides/build_and_config.md)
- **New contributor** → [why this repo matters](why_this_repo_matters.md) →
  ADR index → `make test`
- **AI agent** → `AGENTS.md` → follow its links; do not read everything.
