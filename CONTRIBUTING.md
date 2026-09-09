# Contributing to oka

Full guide lives in the docs: **[Contribution guide](docs/contributing/contribution_guide.mdx)**.

TL;DR:

```bash
make install && make lint && make test
```

- Non-negotiables in [`AGENTS.md`](AGENTS.md) — especially: the default build
  path must never fall back to Gradle.
- Behavior SSOT is code + tests; docs link, never paraphrase.
- Design forks need an ADR in `docs/decisions/` before coding.
