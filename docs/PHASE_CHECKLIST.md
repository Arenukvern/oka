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
- [x] **C1 — Fold platform leakage behind the boundary (ADR-0015).**
      `oka launch` → alias of `oka run device` (`DeviceTarget` shipped by
      `oka_android`); `oka get` nouns route through ADR-0013 tool
      providers; `oka debug dex` moves behind the Android package. Gate:
      `bin/` + verb implementations contain no platform logic (grep gate
      or import-lint test); `oka compare` byte-equivalence preserved.
      Done. `DeviceTarget` + device steps (`packages/oka_android/lib/src/dev/`):
      resolve-newest-APK → install → launch → logcat failure-signature scan,
      compiled to a validated pipeline; dex probe moved to
      `oka_android/lib/src/dev/dex_probe.dart` (pure Dart zip read); `oka
      launch` shim (`lib/src/cli/launch_command.dart`) delegates to `oka run
      device` with zero platform logic (moved flags → typed target config).
      Gate: `test/adr0015_cli_platform_leakage_gate_test.dart` (C1-folded
      files clean; ratchet emptied by the ADR-0015 follow-up — build,
      compare, doctor, get are parse-and-delegate shims over
      `oka_android`'s compare/doctor-checks/provisioning APIs; the only
      remaining exception is the `--skip-badging` flag name).
      Evidence: `test/adr0015_device_target_test.dart` (18 tests: compile
      validation, scripted fake-adb/aapt2 flows, pure helpers),
      `test/adr0015_launch_alias_test.dart` (dispatch equivalence + flags),
      `test/adr0015_dex_probe_test.dart` (probe + CLI delegation); example
      composition root declares `DeviceTarget` (`oka run device` demo).
- [x] **C2 — `oka explain --targets` (ADR-0015).** Discovered targets
      listed with their step chains via the validated-plan surface;
      `oka --help` stays static (core verbs + pointer). Evidence: explain
      output for a project declaring a custom target. Done:
      `describeTarget` (pure, `packages/oka_core/lib/src/targets/describe.dart`)
      + `--oka-describe-targets` machine mode in `okaRun`;
      `oka explain --targets` in `lib/src/cli/explain_command.dart` (no tool
      execution, no device probing; entrypoint-less → `oka init`);
      `test/adr0015_explain_targets_test.dart` (chains, no-execution,
      validation failures, plain-explain regression).
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
- [x] **T1 — Toolchain resolution as data (ADR-0013).** `Toolchain`/
      `ToolProvider` contract; dissolve `SdkLocator` into an ordered,
      printable resolution policy injected as a `ResolvedToolchain`
      artifact; provisioning goes through the store; **stdin prompts
      removed** from all build paths. Tests: precedence-policy unit tests;
      `oka doctor` prints resolved policy; `oka compare` byte-equivalence
      preserved across the refactor.
      Evidence: contracts in `packages/oka_core/lib/src/toolchain/`
      (`ToolQuery`, `ResolvedTool`, `ToolSource`, `ToolResolution`,
      `ToolchainException`, `Toolchain`); policy + injectable env in
      `packages/oka_android/lib/src/build/toolchain.dart`
      (`AndroidToolchain.describe/resolve`, `ResolvedToolchain` seeded into
      `PipelineState.resolvedToolchain` by `AndroidPipeline.run`);
      `sdk_locator.dart` reduced to a thin wrapper delegating to the
      policy; provisioning (`AndroidxJarProvisioner`) still store-based;
      `oka doctor` prints the resolved policy (paths + sources + fixes);
      `test/toolchain_policy_test.dart` (19 precedence/version/doctor
      tests, injected env), `dart analyze` clean, determinism test green.
- [x] **T2 — Device layer through the store (ADR-0013, with H2).**
      adb/emulator provisioning as platform-scoped tool providers;
      install/launch steps consume `ResolvedToolchain`. Evidence: emulator
      e2e already required by H2 — extend with store-backed provisioning.
      Done (T2 scope: provisioning + resolution wiring; the emulator e2e
      evidence itself lands with H2). Evidence: dev steps migrated off the `SdkLocator` wrapper onto
      `ResolvedToolchain` (constructor value → `state.resolvedToolchain` →
      default; `device_steps.dart`, `device_target.dart` — additive
      `toolchain` param, DeviceTarget public shape otherwise unchanged);
      device tools added to the T1 policy as data (`toolchain.dart`:
      `emulator` → `emulator/emulator`, `avdmanager` →
      `cmdline-tools/latest/bin/avdmanager`, `system-images` dir — ordered
      candidates + remediation naming the exact `sdkmanager` command);
      `oka doctor` prints them via the policy value (no CLI change);
      store-backed provisioning (`dev/device_provisioning.dart`,
      `AndroidDeviceProvisioner`): adb resolves policy-first, then store
      (`platform-tools/adb` content key, host-OS-scoped), then a
      **non-interactive** direct download from dl.google.com registered in
      the store — prompt-dependent paths fail closed with
      [ToolchainException] naming the exact command (system images: pointer
      entry in the store, non-interactive `sdkmanager` only when
      `<sdk>/licenses/` pre-accepted, stdin never attached); no stdin
      anywhere. Tests: `test/adr0013_t2_device_store_test.dart` (18 tests:
      source contract — `dev/**` references no `SdkLocator`; policy
      resolution with injected env; store round-trip with fake store + fake
      curl zip — download exactly once, store hit spawns nothing;
      fail-closed remediation; dev steps + full `DeviceTarget` pipeline on
      an injected toolchain). `dart analyze` clean, `dart test` 325
      passing. **Remaining for H2:** real emulator e2e (no emulator
      installed on the dev machine — `oka doctor` reports
      `❌ emulator: not found`, and running one is out of T2 scope, not
      faked); AVD creation/boot steps (`avdmanager create avd` + boot wait)
      composing over this provisioner; `EmulatorSpec` typed fields on
      `DeviceTarget` (deferred — not needed until a boot step consumes
      them, per the no-dead-config rule).
- [x] **P0 — PublishTarget contract + credential-path policy (ADR-0014).**
      `PublishTarget` in `oka_core` (extends `Target`; conformance laws:
      dry-run without credentials, no stdin, no secret values in state/
      logs/events); credential-path resolution policy (explicit config
      path → `OKA_<TARGET>_*` env → `~/.oka/credentials/<target>/`, same
      ordered-policy shape as T1); doctor secret audit (dart-define keys
      matching secret-ish patterns fail with the tier rule); credential
      file inside repo ⇒ must be gitignored. Tests: policy unit tests with
      injected env, audit key-pattern table, dry-run conformance.
      Done. Evidence: `packages/oka_core/lib/src/publish/`
      (`publish_target.dart`: `PublishTarget`, `PublishPlan`,
      `PublishPlanStep` — dry-run is law-as-code: `compile` substitutes
      the upload tail with the plan step; `conformance.dart`:
      `auditPublishConformance`/`expectPublishConformance` over the three
      laws + `FixturePublishTarget`);
      `packages/oka_core/lib/src/credentials/` (`credential_ref.dart`
      redacting `CredentialRef`; `credential_policy.dart`: ordered
      `CredentialResolver` with injected env, tried-candidates +
      remediation, `describePolicyLines`, doctor discovery + repo
      hygiene; `secret_audit.dart`: tested `secretishKeyPatterns`
      constant + pure `auditDartDefines` + `doctorSecretAuditLines`;
      `repo_hygiene.dart`: gitignore-checker seam + default matcher);
      doctor wiring is parse-and-delegate only
      (`lib/src/cli/doctor_command.dart`, `[Secret Audit (ADR-0014)]` +
      `[Credential Policy (ADR-0014)]` blocks; `[Toolchain Policy]`
      byte-identical; gate test `test/adr0014_doctor_delegation_test.dart`).
      Tests: `test/adr0014_credential_policy_test.dart` (precedence,
      hard-fail on configured-but-missing path, env tilde expansion,
      tried+fix, doctor lines, gitignore table),
      `test/adr0014_secret_audit_test.dart` (pattern table, values never
      echoed), `test/adr0014_publish_conformance_test.dart` (three laws
      incl. negative cases). `dart analyze` clean; `dart test` 390
      passing (338 pre-existing + 52 new). Shared-suite extraction stays
      P1 (per ADR-0014 phased plan).
- [ ] **P1 — `oka_play` target package (ADR-0014).** Play Publisher API
      upload steps (service-account JSON by path; AAB → internal track);
      `PublishTarget` conformance suite extracted as a shared package for
      P2+. Evidence: dry-run against a fake endpoint; real upload gated on
      maintainer credentials.
- [ ] **P2 — `oka_huawei` target package (ADR-0014).** AppGallery Connect
      upload + GMS-exclusion build variant composed via `AndroidBuild`
      (artifact validator must catch GMS-dependent steps in the excluded
      composition). Evidence: dry-run + composition-validation tests.
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
