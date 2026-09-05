# Phase Checklist — open work

Only items that need addressing live here. Completed phases (ADR-0006
composition API, ADR-0007 self-resolving builds, ADR-0008 dependency-plan
dry-run) are archived with their evidence in
[archive/PHASE_CHECKLIST_adr0006-0008.md](archive/PHASE_CHECKLIST_adr0006-0008.md).

A phase is done only when its tests and evidence exist (see `AGENTS.md`).

## Open

- [ ] **Typed per-project config in Dart (ADR-0010 — proposed).** Move
      `android:`/`flutter:` base config from oka.yaml into the project's Dart
      pipeline (strictly typed, `copyWith`, programmable); oka.yaml becomes
      optional. Design + staged plan (example app first, last_answer second)
      in [ADR-0010](decisions/0010-typed-dart-project-config.md).
- [ ] **Multi-dex determinism.** d8 part-file count can vary between runs
      (stale parts are already cleaned per run; consider a fixed part count).
- [ ] **H0 — Hot-reload prerequisite audit (ADR-0010).** Prove the oka-built
      debug APK is hot-reload-capable (kernel_blob.bin, VM service reachable,
      attach probe) and record evidence in
      [hot_reload_plan.md](guides/hot_reload_plan.md). Tests: APK-content
      assertions.
- [ ] **H1 — Session manifest / flag parity (ADR-0010).**
      `run_session.json` recorded at build time; `oka dev` validates and
      refuses mismatch; flutter binary resolved from recorded SDK path.
- [ ] **H2 — Device layer (ADR-0010).** adb install/launch/logcat-scrape/
      forward in `oka_android/src/dev/`; command-construction + parser tests;
      emulator e2e evidence.
- [ ] **H3 — `oka dev` v1 daemon session (ADR-0010).**
      `flutter attach --machine` adapter, human TTY loop + `--json` agent
      stream; scripted-fake protocol tests; headless reload e2e evidence.
- [ ] **H4 — `--watch` change classification (ADR-0010).** Dart → reload;
      native/res/manifest → full rebuild routing; debounce + table tests.
- [ ] **H5 — Hot restart + doctor + docs (ADR-0010).** `app.restart`
      semantics, `oka doctor` readiness checks, user-facing docs updated.

## Done

- [x] **Remove demoted cargo-apk hybrid (ADR-0009 — accepted & executed).**
      `rust_wrapper/`, `CargoApkManifest`, `CargoApkConfig` + barrel exports,
      `FlutterAndroidBuilder` wrapper, quarantine test, `example/oka.yaml`
      `cargo_apk:` section removed; docs + AGENTS.md updated. Evidence:
      `dart test` **fully green** (quarantine baseline gone),
      `grep -ri cargo bin/ lib/ packages/*/lib` clean, `oka explain` on
      `example/` unchanged.
