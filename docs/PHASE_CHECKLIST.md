# Phase Checklist — open work

Only items that need addressing live here. Completed phases (ADR-0006
composition API, ADR-0007 self-resolving builds, ADR-0008 dependency-plan
dry-run) are archived with their evidence in
[archive/PHASE_CHECKLIST_adr0006-0008.md](archive/PHASE_CHECKLIST_adr0006-0008.md).

A phase is done only when its tests and evidence exist (see `AGENTS.md`).

## Open

- [x] **C0 — `Target` contract + `oka run` dispatcher (ADR-0015).**
      Typed, const-constructible `Target` (compiles to `Pipeline`) in
      `oka_core`; `Oka(targets: [...])` in the composition root; `oka run
      <target>` dispatch (core verbs reserved, targets cannot shadow);
      unknown-verb errors name available targets; snapshot cache keyed on
      entrypoint content hash. Tests: dispatch, collision rejection,
      target→pipeline validation via existing artifact checker.
      Done. Evidence: `test/adr0015_target_dispatch_test.dart` (18 tests:
      dispatch, collision/validation, unknown-verb listing, no-entrypoint);
      `packages/oka_core/lib/src/targets/target.dart`,
      `lib/src/cli/run_command.dart`. Deferred (latency only, not a
      correctness gate): snapshot-cached entrypoint evaluation keyed on
      content hash — current dispatch shells out to `dart run` like `oka
      build` already does.
- [ ] **C1 — Fold platform leakage behind the boundary (ADR-0015).**
      `oka launch` → alias of `oka run device` (`DeviceTarget` shipped by
      `oka_android`); `oka get` nouns route through ADR-0013 tool
      providers; `oka debug dex` moves behind the Android package. Gate:
      `bin/` + verb implementations contain no platform logic (grep gate
      or import-lint test); `oka compare` byte-equivalence preserved.
- [ ] **C2 — `oka explain --targets` (ADR-0015).** Discovered targets
      listed with their step chains via the validated-plan surface;
      `oka --help` stays static (core verbs + pointer). Evidence: explain
      output for a project declaring a custom target.
- [x] **T0 — ArtifactStore contract + cache unification (ADR-0013).**
      `ArtifactStore`/`ContentKey` in `oka_core`; plain-directory
      `LocalArtifactStore` with human-decodable layout; unify
      `~/.oka/cache/androidx`, `~/.oka/tools`, and dependency caches behind
      it; `oka cache list/gc/why` as interface views. Inputs shared,
      outputs per-project. Tests: key-function + store round-trip; cache
      listing evidence.
      Done. Evidence: `packages/oka_core/lib/src/store/artifact_store.dart`
      (`ContentKey`, `ArtifactStore`, `LocalArtifactStore` — layout
      `<root>/<category>/<name>/<version>-<hash12>/<platform>/` + per-entry
      `oka_store.json`, `OKA_CACHE`-pointable root); AndroidX + Kotlin
      provisioning through the store (`sdk_locator.dart`,
      `auto_resolve.dart`), legacy flat caches still resolve read-only;
      Maven resolver registers entries into the store index
      (`maven_resolver.dart`); `lib/src/cli/cache_command.dart` (`oka cache
      list/gc/why` — `bin/oka.dart` wiring pending, see file header);
      `test/artifact_store_test.dart` (22 tests). `dart analyze` clean,
      `dart test` 245 passing. Stdin prompts removed from AndroidX
      download and SDKMAN paths.
- [ ] **T1 — Toolchain resolution as data (ADR-0013).** `Toolchain`/
      `ToolProvider` contract; dissolve `SdkLocator` into an ordered,
      printable resolution policy injected as a `ResolvedToolchain`
      artifact; provisioning goes through the store; **stdin prompts
      removed** from all build paths. Tests: precedence-policy unit tests;
      `oka doctor` prints resolved policy; `oka compare` byte-equivalence
      preserved across the refactor.
- [ ] **T2 — Device layer through the store (ADR-0013, with H2).**
      adb/emulator provisioning as platform-scoped tool providers;
      install/launch steps consume `ResolvedToolchain`. Evidence: emulator
      e2e already required by H2 — extend with store-backed provisioning.
- [ ] **T3 — Distribution-target ADR (ADR-0014).** Checkpoint for
      `PublishTarget` contract, secrets/auth handling, and target packages
      (`oka_play`, `oka_huawei`, …). Gated on T0/T1. Conformance suite
      (dry-run without credentials, no stdin, no secrets in state) defined
      there.
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
      Example app **and last_answer** migrated to full-Dart (oka.yaml deleted
      in both). Evidence: yaml-config vs Dart-config builds **byte-equivalent**
      (badging + zip entries) in both projects; 13 tests in
      `test/adr0010_typed_config_test.dart` incl. end-to-end
      `--print-config`; `dart test` all green.
- [x] **Skill Steward adoption + benchmarks.** `steward.yaml` (archetype
      `cli_tool`; governance AGENTS.md, validate `just check-contracts`,
      registry `skills.sh.json`); four typed contract actions + smoke
      scenario `oka.contract-status-smoke` — all pass under `--strict`
      (32–747ms per gate); build benchmarks via `just bench`
      (`tool/benchmarks/build_benchmarks.sh`): explain 1.18s, incremental
      build 20.41s, compare 1.35s, debug step 2.76s (example project,
      machine-local evidence in `docs/evidence/`).
- [x] **Multi-dex determinism (ADR-0007 item).** d8 program/lib jar lists
      sorted (parallel dependency resolution made argument order — and hence
      the classesN.dex split — vary between runs); `zipStagingToApk` /
      `zipBundle` write entries in sorted path order instead of filesystem
      order. Evidence: `test/determinism_test.dart` (byte-identical APK/AAB
      across runs and directory orders; real-d8 reproducibility when an SDK
      is present).
- [x] **oka init: full-Dart by default (ADR-0010).** Default scaffold is
      `tool/oka_pipeline.dart` (typed config from pubspec name/version, no
      oka.yaml); `--yaml` opts into the legacy YAML-first flow (with AI
      gradle conversion); `--from-yaml` converts existing yaml 1:1.
      Non-interactive terminals skip overwrite prompts (`--force` forces).
      `test/init_command_test.dart` covers all three flows.
- [x] **OSS publish readiness (ADR-0006 package split).** Split packages get
      LICENSE/README/CHANGELOG; `oka_android` depends on hosted
      `oka_core: ^0.1.6` (path deps are a publish blocker); root resolves
      siblings via `dependency_overrides` for local dev. Publish train
      `oka_core` → `oka_android` → `oka` wired into
      `.github/workflows/pub_publish.yml` with per-package dry-run
      preflight; version-sync gate extended to the split packages.
      Evidence: `dart pub publish --dry-run` — oka_core and oka publishable
      (oka_android resolves once oka_core's first release is up; host
      projects bootstrap with `dependency_overrides`, documented in the
      build guide).
- [x] **Adoption fixes surfaced by last_answer (behavior-preserving):**
      `archive` bumped to ^4 (unblocks host apps using image /
      flutter_native_splash); pipeline-level overrides seeded into
      `PipelineState` — explicit `steps:` lists now get fast-settings
      (exclude_plugins, extra_deps, manifest, icon, signing,
      resource_configs, extra_assets, local_aars, max_size_mb) instead of
      silently dropping them (pre-existing ADR-0006 gap); `flutter assemble`
      subprocesses receive the located `ANDROID_SDK_ROOT` (projects with a
      stale android/local.properties no longer fail build_hooks).

- [x] **Remove demoted cargo-apk hybrid (ADR-0009 — accepted & executed).**
      `rust_wrapper/`, `CargoApkManifest`, `CargoApkConfig` + barrel exports,
      `FlutterAndroidBuilder` wrapper, quarantine test, `example/oka.yaml`
      `cargo_apk:` section removed; docs + AGENTS.md updated. Evidence:
      `dart test` **fully green** (quarantine baseline gone),
      `grep -ri cargo bin/ lib/ packages/*/lib` clean, `oka explain` on
      `example/` unchanged.
