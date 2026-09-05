# Phase Checklist — open work

Only items that need addressing live here. Completed phases (ADR-0006
composition API, ADR-0007 self-resolving builds, ADR-0008 dependency-plan
dry-run) are archived with their evidence in
[archive/PHASE_CHECKLIST_adr0006-0008.md](archive/PHASE_CHECKLIST_adr0006-0008.md).

A phase is done only when its tests and evidence exist (see `AGENTS.md`).

## Open

- [ ] **Multi-dex determinism.** d8 part-file count can vary between runs
      (stale parts are already cleaned per run; consider a fixed part count).
- [ ] **H0 — Hot-reload prerequisite audit (ADR-0011).** Prove the oka-built
      debug APK is hot-reload-capable (kernel_blob.bin, VM service reachable,
      attach probe) and record evidence in
      [hot_reload_plan.md](guides/hot_reload_plan.md). Tests: APK-content
      assertions.
- [ ] **H1 — Session manifest / flag parity (ADR-0011).**
      `run_session.json` recorded at build time; `oka dev` validates and
      refuses mismatch; flutter binary resolved from recorded SDK path.
- [ ] **H2 — Device layer (ADR-0011).** adb install/launch/logcat-scrape/
      forward in `oka_android/src/dev/`; command-construction + parser tests;
      emulator e2e evidence.
- [ ] **H3 — `oka dev` v1 daemon session (ADR-0011).**
      `flutter attach --machine` adapter, human TTY loop + `--json` agent
      stream; scripted-fake protocol tests; headless reload e2e evidence.
- [ ] **H4 — `--watch` change classification (ADR-0011).** Dart → reload;
      native/res/manifest → full rebuild routing; debounce + table tests.
- [ ] **H5 — Hot restart + doctor + docs (ADR-0011).** `app.restart`
      semantics, `oka doctor` readiness checks, user-facing docs updated.

## Done

- [x] **Typed per-project config in Dart (ADR-0010 — accepted & executed).**
      `AndroidBuild`/`FlutterBuild` typed values (oka_core), deep-merge over
      oka.yaml in `okaRun` (+ `--print-config`), entrypoint discovery
      (`tool/oka_pipeline.dart` -> `bin/oka_pipeline.dart`) in build/explain/
      doctor/debug, `oka init --from-yaml` 1:1 converter + `--dart` scaffold.
      Example app migrated to full-Dart (`example/tool/oka_pipeline.dart`,
      oka.yaml deleted). Evidence: same-hook A/B **byte-equivalence** —
      badging, `AndroidManifest.xml`, `resources.arsc`, `classes.dex`
      identical between yaml-config and Dart-config builds (residual diffs:
      example's timestamped `build_info.txt` stamp + signature cascade);
      9 tests in `test/adr0010_typed_config_test.dart` incl. end-to-end
      `--print-config`; `dart test` all green.

- [x] **Remove demoted cargo-apk hybrid (ADR-0009 — accepted & executed).**
      `rust_wrapper/`, `CargoApkManifest`, `CargoApkConfig` + barrel exports,
      `FlutterAndroidBuilder` wrapper, quarantine test, `example/oka.yaml`
      `cargo_apk:` section removed; docs + AGENTS.md updated. Evidence:
      `dart test` **fully green** (quarantine baseline gone),
      `grep -ri cargo bin/ lib/ packages/*/lib` clean, `oka explain` on
      `example/` unchanged.
