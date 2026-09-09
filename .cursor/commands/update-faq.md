# Update FAQ

After a code change, sync documentation. Stay short & smart.

1. Classify the change:
   - Architectural / internal trade-off → `docs/guides/design_faq.mdx` (edit existing Q&A first) or new ADR in `docs/decisions/`
   - Command / API usage pattern → `docs/guides/build_and_config.mdx`
   - Both → both, but never duplicate paragraphs between them
2. Verify against the actual codebase — document what exists, not wishful APIs.
3. Remove or supersede Q&As that no longer apply.
4. Keep answers ≤3 sentences; long examples belong in code/examples.
5. If a design fork was decided, ensure an accepted ADR exists in `docs/decisions/` and update its `index.mdx`.
