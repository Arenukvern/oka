# Contributing to oka

Full guide lives in the docs: **[Contribution guide](docs/contributing/contribution_guide.mdx)**.

Install Dart 3.13 or newer and `just` for the contributor tooling. Flutter and the Android SDK are
required for real Android build tests.

TL;DR:

```bash
just install && just lint && just test && just check-contracts
```

- Non-negotiables in [`AGENTS.md`](AGENTS.md) — especially: the default build
  path must never fall back to Gradle.
- Behavior SSOT is code + tests; docs link, never paraphrase.
- Design forks need an ADR in `docs/decisions/` before coding.

## Recognition

Every kind of contribution counts — code, docs, examples, bug reports,
design ideas, reviews. Oka uses the
[all-contributors spec](https://github.com/all-contributors/all-contributors):
add yourself with `npx all-contributors add <username> <contribution>`
(config in `.all-contributorsrc`; it updates the table in `README.md`), or
just ask in your PR and we'll add you.
