# Phase Checklist — open work

Only items that need addressing live here. Completed phases (ADR-0006
composition API, ADR-0007 self-resolving builds, ADR-0008 dependency-plan
dry-run) are archived with their evidence in
[archive/PHASE_CHECKLIST_adr0006-0008.md](archive/PHASE_CHECKLIST_adr0006-0008.md).

A phase is done only when its tests and evidence exist (see `AGENTS.md`).

## Open

- [ ] **Remove demoted cargo-apk hybrid (ADR-0009 — proposed, awaiting
      sign-off).** Zero production usage; the quarantine test is the only
      thing touching `rust_wrapper/` and it fails every `dart test`/CI run.
      Full removal plan in [ADR-0009](decisions/0009-remove-cargo-apk-hybrid.md).
      Effect: `dart test` fully green, baseline caveat ("≤1 rust_wrapper
      failure") disappears, dead `cargo_apk:` config surface removed.
- [ ] **Multi-dex determinism.** d8 part-file count can vary between runs
      (stale parts are already cleaned per run; consider a fixed part count).

## After the rust removal (follow-ups)

- [ ] AGENTS.md: drop the `rust_wrapper/Cargo.toml` non-negotiable (moot).
- [ ] `docs/start_here/why_this_repo_matters.md` + `design_faq.md` +
      `contribution_guide.md`: update demotion wording to removal (ADR-0001/0009).
