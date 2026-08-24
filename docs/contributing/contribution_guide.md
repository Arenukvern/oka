# Contributing

Thanks for your interest in oka! The project is agent-first: agents execute,
humans steer. That shapes how contributions work.

## Setup

```bash
git clone https://github.com/Arenukvern/oka.git && cd oka
make install    # dart pub get
make test       # dart test
make lint       # dart analyze
```

## Ground rules

1. **Non-negotiables** (see `AGENTS.md`):
   - The default build path must never shell out to `flutter build apk` /
     Gradle as success.
   - Never mutate shared `rust_wrapper/Cargo.toml`.
2. **Behavior SSOT is code + tests.** Docs link to implementation; they never
   paraphrase it.
3. **Design forks need an ADR first.** If your change settles a trade-off,
   open/propose an ADR in `docs/decisions/` before coding.
4. **Phases are done only with evidence.** Update
   [`docs/PHASE_CHECKLIST.md`](../PHASE_CHECKLIST.md) with test references.

## Docs sync

After any behavior change, update the matching doc layer — see the table in
[`docs/start_here/docs_map.md`](../start_here/docs_map.md):

| Change type | Update |
|---|---|
| Internal trade-off / architecture | `docs/guides/design_faq.md` Q&A and/or new ADR |
| Public API / usage / config key | `docs/guides/build_and_config.md` (copy-paste valid) |
| Settled strategic decision | `docs/decisions/NNNN-*.md` + index row |
| Phase-level completion | `docs/PHASE_CHECKLIST.md` evidence table |

## Pull requests

- Keep changes minimal and focused; match existing style.
- Add/adjust tests for anything that changes packaging or pipeline behavior.
- Run `make lint && make test` before pushing.
- Use conventional commit titles (`feat:`, `fix:`, `docs:`).
