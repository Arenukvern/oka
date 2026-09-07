# Archived phase checklist — ADR-0013/0014/0015 + ADR-0011 phases (2026-09)

> Archived 2026-09: all listed phases complete with evidence.
> Open work now lives in [docs/PHASE_CHECKLIST.md](../PHASE_CHECKLIST.md).
> Earlier completed phases (ADR-0006/0007/0008) are archived in
> [PHASE_CHECKLIST_adr0006-0008.md](PHASE_CHECKLIST_adr0006-0008.md).

# Phase Checklist (archived)

Evidence-based phase tracking (see `AGENTS.md` non-negotiables). A phase is
done only when its tests and evidence exist.

## ADR-0013 — Toolchain, provisioning, artifact store

- [x] **T0 — ArtifactStore contract + cache unification.**
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
- [x] **T1 — Toolchain resolution as data.** `Toolchain`/
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
- [x] **T2 — Device layer through the store (with H2).**
      adb/emulator provisioning as platform-scoped tool providers;
      install/launch steps consume `ResolvedToolchain`. Evidence: emulator
      e2e already required by H2 — extend with store-backed provisioning.
      Done (T2 scope: provisioning + resolution wiring; the emulator e2e
      evidence itself landed with H2). Evidence: dev steps migrated off the `SdkLocator` wrapper onto
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
      passing. (The real emulator e2e evidence landed under H2; AVD
      creation/boot steps and `EmulatorSpec` typed fields on `DeviceTarget`
      remained deferred until a boot step consumes them, per the
      no-dead-config rule.)

## ADR-0014 — Distribution targets + secrets model

- [x] **P0 — PublishTarget contract + credential-path policy.**
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
      passing (338 pre-existing + 52 new). Shared-suite extraction landed
      in P1 as `oka_conformance` (per the ADR-0014 phased plan).
- [x] **P1 — `oka_play` target package.** `PlayPublishTarget`
      in `packages/oka_play` (`extends PublishTarget`; `publish-play`,
      dry-run-by-default; compiles to `stage-aab` → `publish-plan` under
      dry-run, `stage-aab` → `play-upload` real; `PlayTrack` typed config
      with `internal` default, staged-rollout `userFraction`,
      `releaseName`; metadata flows into the plan). Upload tail:
      `play_upload_step.dart` — AAB by `Artifact<String>('aab-path')`,
      service-account JSON by *path* via the P0 `CredentialResolver`
      (typed-config path → `OKA_PLAY_SERVICE_ACCOUNT_JSON` env →
      well-known location; injected-env testable), shape-checked by field
      name only (`play_credentials.dart`), JWT (RS256) → OAuth token
      exchange via googleapis_auth over an injectable base client, then
      the androidpublisher/v3 Edits flow (`play_publisher_client.dart`:
      create edit → upload AAB → assign track → commit) over an injectable
      `http.Client`; failures are `StepResult.failure` naming status +
      remediation, never credential values. Shared suite extracted as
      `packages/oka_conformance` (`expectPublishConformance` re-exported
      from oka_core — the oka_core contract is untouched; plus
      `expectPlanShape`/`expectPlanDescribes` plan-shape assertions,
      `expectNoSecretMaterial`/`expectStateRedacted` redaction assertions,
      and the scripted offline `FakeHttpTransport` that throws on
      unexpected requests — the `universal_storage_conformance` pattern;
      usable as-is by P2+ targets). CLI untouched (targets are
      project-declared — the ADR-0015 payoff). Tests: `test/`
      `play_conformance_test.dart` (full ADR-0014 suite over
      `PlayPublishTarget` incl. no-stdin scan of `lib/src`, zero-HTTP
      dry-run via `assertNoRequests`, plan shape, redaction, credential
      policy with injected env incl. hard-fail on configured-but-missing
      path), `play_upload_flow_test.dart` (token exchange + full Edits
      flow against the fake transport — exact ordered request URLs, JWT
      bearer-grant + RS256 header + `iss`/`scope`/`aud` claims, AAB bytes
      verbatim, track release body incl. `inProgress`+fraction rollout,
      failure paths: missing AAB / empty packageName / unresolvable
      credential / malformed service-account / API 403 — all offline, no
      network). Done. Evidence: dry-run plan
      (`dart run` over `PlayPublishTarget()`):
      `target: publish-play (dry run — nothing was uploaded)` /
      `endpoint: Google Play Publisher API (androidpublisher/v3)` /
      `track: internal` / `artifact: aab-path → …/app-release.aab` /
      `metadata.packageName: dev.example.app` /
      `credential: CredentialRef(play/service-account-json →
      [redacted])`. Real upload gated on maintainer credentials (the
      synthetic test key in `test/synthetic_credentials.dart` is generated
      fixture material, labeled as such, and guards nothing). `dart
      analyze` clean (root + both new packages); `dart test` 390 passing
      at root (unchanged), 27 in `oka_play`, 11 in `oka_conformance`.
- [x] **P2 — `oka_huawei` target package.** AppGallery Connect
      upload + GMS-exclusion build variant composed via `AndroidBuild`
      (artifact validator must catch GMS-dependent steps in the excluded
      composition). Done. Evidence:
      `packages/oka_huawei/lib/src/` (`huawei_publish_target.dart`:
      `HuaweiPublishTarget extends PublishTarget` — `publish-huawei`,
      dry-run default; compiles to `huawei-stage-aab` → `publish-plan`
      under dry-run, `huawei-stage-aab` → `agc-publish` real; composes
      `HuaweiBuildVariant`; `agc_publish_step.dart`:
      `HuaweiStageAabStep` (pure path resolution, no existence check — the
      real tail enforces it) + `AgcPublishStep` (AGC token fetch →
      upload-url → PUT artifact → submit, credential file resolved by path
      via the P0 `CredentialResolver`, secrets never leave step-local
      scope); `agc_api.dart`: `AgcClient` over an injectable `http.Client`
      (`AgcEndpoints` default
      `https://connect-api.cloud.huawei.com`), redacting `AgcToken` /
      `AgcCredentials`, `AgcApiException` naming status + ret.code — never
      bodies/credentials; `agc_credentials.dart`;
      `huawei_release_config.dart`: typed track / staged-rollout /
      release-note file paths; `gms_variant.dart`: `HuaweiBuildVariant` —
      `extraDeps` filtered through `isGmsCoordinate` (oka_android seam),
      `excludedGmsDeps` inspectable). **Additive seam in oka_android**
      (justification: declaring GMS-dependency artifacts required typed ids
      no existing file provides; no existing behavior modified):
      `packages/oka_android/lib/src/gms_artifacts.dart` — `gms-dep:<coordinate>`
      version-free artifact ids, `isGmsCoordinate` / `splitGmsDependencies`
      (GMS group prefixes as data), `GmsDependencyProviderStep` (declares +
      existence-checks resolved GMS jars; absent in GMS-excluded variants).
      **Composition-validation demonstration:** a step requiring
      `gmsDependencyArtifact('com.android.billingclient:billing-ktx')` in a
      GMS-excluded composition fails `Pipeline.validate()` /
      `describeTarget(...).isValid` naming
      `gms-dep:com.android.billingclient:billing-ktx` and the step —
      **before any tool runs** (the test's step records execution and
      asserts it never happened); positive control: with
      `GmsDependencyProviderStep` present the same step validates and runs.
      Tests: `packages/oka_huawei/test/huawei_conformance_test.dart` (the
      three ADR-0014 laws via the P1 shared suite
      `oka_conformance`/`expectPublishConformance` + plan-shape and
      redaction assertions + zero-HTTP proof),
      `test/agc_flow_test.dart` (token → upload-url → PUT → submit against
      the scripted `FakeHttpTransport`, byte-exact upload, ordered requests,
      failure paths: missing artifact / missing credential file with
      tried-candidates + fix / malformed credentials / HTTP 401 / ret.code
      ≠ 0 / missing release-note file — every error asserted free of secret
      material), `test/gms_composition_test.dart` (classification, variant
      filtering, the validator rejection + positive control);
      `packages/oka_android/test/gms_artifacts_test.dart` (seam unit tests).
      `dart analyze` clean for oka_huawei/oka_android (remaining analyze
      infos in packages/oka_play belonged to P1, in flight); root `dart test`
      390 passing (unchanged); `packages/oka_huawei` 31 passing,
      `packages/oka_android` 11 passing. Sample dry-run plan
      (`plan.describeLines()`): `target: publish-huawei (dry run — nothing
      was uploaded)` / `endpoint: AppGallery Connect Publishing API
      (https://connect-api.cloud.huawei.com)` / `track: beta` / `artifact:
      aab-path → <buildDir>/app-release.aab` / `metadata.appId: 110012345`
      / `credential: CredentialRef(huawei/agconnect-credentials →
      [redacted])`. Real uploads against production AGC remain gated on
      maintainer credentials.

## ADR-0015 — CLI verb/target split

- [x] **C0 — `Target` contract + `oka run` dispatcher.**
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
- [x] **C1 — Fold platform leakage behind the boundary.**
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
- [x] **C2 — `oka explain --targets`.** Discovered targets
      listed with their step chains via the validated-plan surface;
      `oka --help` stays static (core verbs + pointer). Evidence: explain
      output for a project declaring a custom target. Done:
      `describeTarget` (pure, `packages/oka_core/lib/src/targets/describe.dart`)
      + `--oka-describe-targets` machine mode in `okaRun`;
      `oka explain --targets` in `lib/src/cli/explain_command.dart` (no tool
      execution, no device probing; entrypoint-less → `oka init`);
      `test/adr0015_explain_targets_test.dart` (chains, no-execution,
      validation failures, plain-explain regression).

## ADR-0011 — Agent-first dev loop

- [x] **H0 — Hot-reload prerequisite audit.** Prove the oka-built
      debug APK is hot-reload-capable (kernel_blob.bin, VM service reachable,
      attach probe) and record evidence in
      [hot_reload_plan.md](../guides/hot_reload_plan.md). Tests: APK-content
      assertions.
      Done. Evidence (full transcripts in the plan's H0 evidence block):
      oka-built debug APK zip contains `kernel_blob.bin` (46 MB) +
      `isolate_snapshot_data` + `libflutter.so`, **no AOT `libapp.so`**;
      `-dTrackWidgetCreation=true` asserted; headless emulator (API 34
      arm64) live chain: `oka run device` install → launch → logscan clean,
      oka's `AdbTool` scraped the VM service URI (`The Dart VM service is
      listening on http://127.0.0.1:38635/…/` — newer Flutter wording,
      parser now matches both spellings), `adb forward tcp:0` + HTTP
      `getVM` over the forwarded port returned the VM + 1 isolate
      (`PROBE_OK`); `flutter attach --machine` connects to the oka-built
      APK and reaches `app.started` (discovers the service URI itself);
      `flutter run --machine --use-application-binary` is Gradle-free (0
      mentions in the transcript) but re-installs the APK itself.
      **Decision recorded:** H3 integrates via `attach --machine`; oka owns
      install → launch. Tests: `test/adr0011_apk_contents_test.dart`
      (static arg assertions + real-pipeline zip-content assertions with
      SDK-present skip). No blockers remain.
- [x] **H1 — Session manifest / flag parity.**
      `run_session.json` recorded at build time; `oka dev` validates and
      refuses mismatch; flutter binary resolved from recorded SDK path.
      Done. **Format (schema 1, documented in `run_session.dart`):**
      `run_session.json` next to the APK with fixed field order — `schema`
      (1, readers refuse unknown schemas), `oka_version`, `recorded_at`
      (ISO8601 UTC, the only volatile field), `flutter_sdk_path`,
      `engine_revision` (`bin/internal/engine.version` of the recording
      SDK), `target_file`, `build_mode`, `dart_defines` (merged
      `--dart-define` + `--dart-define-from-file`, trimmed, sorted keys),
      `application_id`, `abis`, `apk_path`, `flavor`,
      `track_widget_creation`. Evidence:
      `RecordRunSessionStep` appended to both default pipelines (APK+AAB)
      and to the example composition root — `oka build apk --debug` on
      `example/` emits the manifest (golden-file test asserts the exact
      JSON modulo `recorded_at`); `validateRunSession` refuses on mismatch
      naming every differing field + fix (never warn-and-continue);
      `checkDevSession` (oka_android) = `oka dev` preflight: refuses
      no-APK / pre-manifest builds, flag mismatches (target/defines/mode/app
      id), engine drift at the recorded path, missing flutter binary — and
      resolves the session flutter binary from the **recorded SDK path**,
      never PATH. CLI stays parse-and-delegate (`lib/src/cli/dev_command.dart`):
      live transcripts — happy path validates and prints the session line;
      `oka dev --dart-define=STORE=sideload` refuses with
      `dart_defines (STORE): recorded "", requested "STORE=sideload"`, exit 1;
      `oka dev --target=lib/alt.dart` refuses naming `target_file`. Tests:
      `test/adr0011_run_session_test.dart` (33 tests: round-trip,
      deterministic encoding, unknown-field tolerance, corrupt/unknown-
      schema fail-closed, per-field mismatches, CLI↔manifest define
      normalization parity, golden step output, `checkDevSession` table).
- [x] **H2 — Device layer.** adb install/launch/logcat-scrape/
      forward in `oka_android/src/dev/`; command-construction + parser tests;
      emulator e2e evidence.
      Done. Evidence: `adb_tool.dart` (pure argv builders `adbDevicesArgs` /
      `adbInstallArgs` / `adbLaunchArgs` / `adbForwardArgs` / logcat args;
      parsers `parseAdbDevices` / `parseVmServiceUri` / `parseForwardPort`;
      `classifyAdbFailure` → typed kind + oka-style fix for unauthorized /
      no-device / device-offline / signing-mismatch / install-failed /
      adb-missing / unknown; `AdbTool` executor with injectable path +
      process runner; bounded `awaitVmServiceUri` poll);
      `AwaitVmServiceStep` / `ForwardVmServiceStep` in the validated chain
      (artifacts `vm_service_uri`, `vm_service_local_port`).
      `test/adr0011_adb_tool_test.dart` (24 tests incl. scripted fake adb
      binaries — the `adr0015` pattern — and the emulator-captured
      announcement line as a regression fixture). Emulator e2e evidence:
      provisioned non-interactively (licenses pre-accepted; see the H0
      evidence block for the exact one-time commands), then live
      `oka run device` on `emulator-5554` (install → launch → pid alive →
      no failure signatures) and the AdbTool scrape+forward+getVM probe
      (`PROBE_OK`). Device selection (`oka dev -d`) and its zero/multiple-
      device errors landed with H3's session wiring (parse-and-delegate —
      the `AdbDevice.ready` contract is already in place).
- [x] **H3 — `oka dev` v1 daemon session.**
      `flutter attach --machine` adapter, human TTY loop + `--json` agent
      stream; scripted-fake protocol tests; headless reload e2e evidence.
      Done. Evidence (full transcripts in the plan's H3 evidence block):
      `daemon_adapter.dart` (oka_android/src/dev — the only file that knows
      wire details) spawns the recorded-SDK binary with
      `attach --machine -d <id>` (never ambient PATH) and prepends the
      resolved tool directory to the child's PATH (live finding: the
      oka-managed SDK is otherwise invisible to the attach child).
      **Live-probed protocol correction (supersedes one H0 assumption):**
      `app.reload` does not exist in flutter_tools 3.47.0-0.4.pre — hot
      reload = `app.restart {appId, fullRestart: false}`, hot restart =
      `fullRestart: true`, `app.stop`/`app.detach` take the `appId`
      announced by `app.start`; the older `app.reload` spelling is kept as
      a feature-detected fallback. Live e2e on the headless AVD (API 34):
      `oka run device` → `oka dev --json -d emulator-5554` reaches
      `session.ready` (VM service scraped + forwarded via the H2 steps),
      then programmatic reload completes (`reload.result ok:true`,
      `progressId: hot.reload`) and hot restart completes
      (`restart.result ok:true`, `progressId: hot.restart`), then
      `detach` sends `app.detach` and the app keeps running (pid verified
      after detach; the `quit` → `app.stop` + `daemon.shutdown` tear-down
      is asserted at the scripted-fake tier) — the agent-usable acceptance
      test passes headless. Also verified live: with the oka-managed SDK
      absent from the invoking shell's PATH, `oka dev` still reaches
      `session.ready` (the adapter prepends the resolved tools dir to the
      attach child's PATH).
      Refusals: profile/release, H1 manifest mismatch, `-d` selection
      (zero/multiple/unauthorized → `classifyAdbFailure`). CLI stays a
      parse-and-delegate shim (leakage gate green). Tests:
      `test/adr0011_daemon_adapter_test.dart` (11: scripted stdio fake,
      no real flutter) + `test/adr0011_dev_session_test.dart` (23:
      control tables, device-selection table, human/JSON rendering,
      diagnostics, `DevFlow` rebuild-then-reattach).
- [x] **H4 — `--watch` change classification.** Dart → reload;
      native/res/manifest → full rebuild routing; debounce + table tests.
      Done. Evidence: `watch.dart` (`classifyChanges` table — Dart under
      `lib/` → reload; non-Dart under `lib/` (bundled assets) → rebuild;
      test/tool/bin → ignore; android/res/manifest/assets/oka.yaml/
      pubspec → rebuild; build/meta → ignore; strongest action wins),
      quiet-period `debounceStream`, `watchCommandStream` routing into the
      session control loop, `--rebuild-on-native` → `DevFlow` rebuild →
      reinstall → relaunch → re-attach (reusing the same device steps);
      `watcher` is a direct `oka_android` dependency. Live headless watch
      loop on the emulator: edit `lib/main.dart` →
      `reload.result ok:true` without any keyboard; touch
      `AndroidManifest.xml` → `rebuild.required` + the exact command
      (`fullRebuildMessage`), reload never suggested. Tests:
      `test/adr0011_watch_test.dart` (17: table classification, debounce,
      routing, fixture-tree watch paths, one real-watcher smoke test).
- [x] **H5 — Hot restart + doctor + docs.** `app.restart`
      semantics, `oka doctor` readiness checks, user-facing docs updated.
      Done. Evidence: hot restart live on the emulator (`restart.result
      ok:true` — full kernel recompile + restart under flutter_tools
      semantics; state-loss stated in the TTY help, `--json` usage, and
      docs); `oka doctor` gained `[Dev Loop (ADR-0011)]` readiness checks
      (`devLoopDoctorChecks`: debug session manifest present, recorded-SDK
      flutter binary, adb + ready device; manifest/binary failures
      blocking, device absence advisory) — live transcript in the plan's
      H5 evidence block, unit-tested with scripted fakes
      (`test/adr0011_dev_doctor_test.dart`, 7). User-facing docs updated:
      `build_and_config.md` Dev-loop section, `quick_recipes.md`
      three-flow recipes, README — presenting `oka run device` (= `oka
      launch`, one-shot install+launch+logscan, no session) and `oka dev`
      (parity check → device steps → attach session) as one coherent
      story; docs link to behavior, never paraphrase.

## Done (cross-cutting, archived together)

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
