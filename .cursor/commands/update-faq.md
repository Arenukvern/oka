# Update FAQ

After a code change, sync documentation. Stay short & smart.

1. Classify the change:
   - Architectural / internal trade-off → `docs/DESIGN_FAQ.mdx` (edit existing Q&A first) or new ADR in `docs/decisions/`
   - Command / API usage pattern → `docs/DX_FAQ.mdx` (Memory Palace location + code block)
   - Long examples / station detail → `docs/guides/build_and_config.mdx` or the topic guide
   - Both why and how → update DESIGN and DX; **never** duplicate paragraphs
2. Verify against the actual codebase — run `dart run packages/oka/bin/oka.dart <cmd> --help` or relevant tests; document what exists, not wishful APIs.
3. Remove or supersede Q&As that no longer apply.
4. Keep DESIGN answers ≤3 sentences; DX blocks must be copy-paste valid.
5. If a design fork was decided, ensure an accepted ADR exists in `docs/decisions/` and update its `index.mdx`.
6. Update root symlinks only if canonical paths move (`DESIGN_FAQ.md` → `docs/DESIGN_FAQ.mdx`, `DX_FAQ.md` → `docs/DX_FAQ.mdx`).