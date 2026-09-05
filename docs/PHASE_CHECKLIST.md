# Phase Checklist — open work

Only items that need addressing live here. Completed phases (ADR-0006
composition API, ADR-0007 self-resolving builds, ADR-0008 dependency-plan
dry-run) are archived with their evidence in
[archive/PHASE_CHECKLIST_adr0006-0008.md](archive/PHASE_CHECKLIST_adr0006-0008.md).

A phase is done only when its tests and evidence exist (see `AGENTS.md`).

## Open

- [ ] **Multi-dex determinism.** d8 part-file count can vary between runs
      (stale parts are already cleaned per run; consider a fixed part count).

## Done

- [x] **Remove demoted cargo-apk hybrid (ADR-0009 — accepted & executed).**
      `rust_wrapper/`, `CargoApkManifest`, `CargoApkConfig` + barrel exports,
      `FlutterAndroidBuilder` wrapper, quarantine test, `example/oka.yaml`
      `cargo_apk:` section removed; docs + AGENTS.md updated. Evidence:
      `dart test` **fully green** (quarantine baseline gone),
      `grep -ri cargo bin/ lib/ packages/*/lib` clean, `oka explain` on
      `example/` unchanged.
