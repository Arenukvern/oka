# Phase Checklist

Evidence-based phase tracking (see `AGENTS.md` non-negotiables). A phase is
done only when its tests and evidence exist.

## Phase: ADR-0006 declarative composition API + package split

- **Status:** in progress (core complete; e2e validated; docs pending final pass)
- **ADR:** [0006](decisions/0006-dart-entrypoint-hooks.md) (accepted)

### Done

- [x] Package split: `oka_core` (contracts) + `oka_android` (platform) + `oka` (CLI)
- [x] Typed `BuildContext` value class with `copyWith` (replaces map extension type)
- [x] `Artifact<T>` typed artifact keys + `requires`/`provides` on all default steps
- [x] Composition-time artifact-chain validation in `Pipeline.run` (fails before any tool runs)
- [x] `Oka` / `PlatformPipeline` composition root + `okaRun` entrypoint
- [x] `oka build` delegation via `pipeline.dart_entrypoint` (ADR-0006)
- [x] `oka init` generates `dart_entrypoint`-aware scaffold (commented
      `pipeline.dart_entrypoint` example + pointer to
      `example/bin/custom_pipeline.dart`) — `test/init_command_test.dart`
- [x] `ManifestSpec` typed manifest value rendered by host-codegen (byte-compat with legacy)
- [x] Dart-define plumbing: `--dart-define`, `--dart-define-from-file`, `--target` (G1/G3)
- [x] Signing config: `SigningConfig` (yaml env-indirection + `android/key.properties`) (G2)
- [x] Resource configs: aapt2 `-c en,ru` threading (G4)
- [x] Transitive dependency resolution: parent-POM version resolution, BOM imports,
      parallel BFS, per-artifact failure isolation, per-run memoization (G6)
- [x] Incremental step cache: `plugin-packaging`, `flutter-assemble`, `release-aot`,
      `compile-and-dex` fingerprinted (content-hash for small files)
- [x] Tests: 173 passing (1 pre-existing rust_wrapper quarantine failure, unchanged baseline)
- [x] E2E #1: `example/` app — debug APK via default pipeline (188s cold)
- [x] E2E #2: `example/` app — declarative hook (`bin/custom_pipeline.dart` via
      `dart_entrypoint`) with custom steps interleaved
- [x] E2E #3: **last_answer** (first production app) — debug APK 157s cold /
      **23.9s incremental**; verified: package `dev.xsoulspace.lastanswer`,
      versionCode 51 / versionName 3.22.0, 3 permissions, 3 deeplinks
      (incl. scheme-only RuStore), cleartext flag, label, `en/ru` resource configs
- [x] E2E #4: **last_answer release AAB** with exact store flags
      (`--release --dart-define-from-file=configs/envs/prod.json
      --dart-define=STORE=googlePlay --target lib/main_prod.dart`) — 76.9s warm;
      **bundletool 1.17 `validate` PASSES** (exit 0). 67.69 MB after fixing
      dex-part accumulation and BundleConfig.pb bundletool_version field.
      Debug-signed (no release keystore on this machine — expected warning
      printed); supply `android/key.properties` for store upload.

### Notable fixes surfaced by the last_answer e2e (evidence of the pipeline model)

- `Accept-Encoding: gzip` hang on vkpartner artifactory → explicit `identity`
- jar→aar packaging fallback (ML Kit ships AAR-only)
- Google-Maven routing for `com.google.mlkit`/`firebase` groups
- Maven parent-POM + BOM-import version resolution (tika/slf4j class of POMs)
- `add("implementation", "g:a:v")` Kotlin DSL parsing
- Java 17 sources (pattern matching) — `java_version` threading
- `exclude_plugins` for test-only plugins (`integration_test`)

### Open

- [ ] Multi-dex determinism: d8 part-file count can vary between runs (stale parts
      now cleaned; consider fixed part count)

## Phase: ADR-0007 self-resolving, self-checking builds

- **Status:** in progress
- **Scope:** see [hardening roadmap](guides/hardening_roadmap.md)

### Done

- [x] Roadmap doc + ADR-0007 accepted
- [x] `MavenResolver` + `MavenRepoRegistry` (declarative repo routing) + single
      `MavenCoordinate` in `oka_core` (duplicate removed)
- [x] `PipelineEvent`s (StepStarted/Finished, CacheEvent, BuildWarning, Log) +
      `ProcessRunner` in `oka_core`
- [x] `oka build --dry-run` / `oka explain` — validated plan, zero tool invocations
- [x] `PostBuildLintStep` wired into APK/AAB pipelines: manifest version rule,
      debug-sign gate (`--allow-debug-signing` escape), size budget
      (`pipeline.max_size_mb`), BundleConfig version check
- [x] Auto-resolve: kotlinc self-install (`OKA_NO_AUTO_INSTALL=1` escape),
      java-level auto-bump (detects `VERSION_NN` in plugin gradle),
      pubspec version fallback, dev-dep plugin exclusion (release)
- [x] Gradle fixture corpus (mobile_scanner, file_picker, rustore) + auto-resolve tests
- [x] `oka doctor`: build-health section (kotlinc, bundletool, maven cache,
      incremental cache, package_config staleness)
- [x] E2E re-verified after refactor: last_answer explain ✅, incremental
      build **22.3s** ✅
- [x] `oka compare <apk1> <apk2>` formal byte-equivalence gate: `aapt2 dump
      badging` diff (package, versionCode/Name, permissions, intent-filter
      metadata) + zip entry diff (only-in / crc32-changed); exit 1 on
      differences, `--quiet` escape — `packages/oka_android/lib/src/compare.dart`,
      `lib/src/cli/compare_command.dart`, `test/compare_test.dart`
- [x] `oka debug step <name>` single-step probe runner: default-pipeline prefix
      (upstream artifact providers) against the project's `.oka_cache`,
      okaRun-identical context, `--list` discovery from
      `AndroidPipeline.defaultSteps` — `lib/src/cli/debug_command.dart`,
      `test/debug_command_test.dart`
- [x] Conditional-dep dedup: `inConditional`/`conditionalGroup` on
      `ParsedGradleDep` (if/else scope tracking in the parser); if/else variants
      collapse to gradle's default branch (first variant) with a printed notice
      (mobile_scanner ML Kit bundled/unbundled) — `packages/oka_android/lib/src/
      build/gradle_dep_parser.dart` + `plugin_packager.dart`,
      `test/gradle_conditional_dedup_test.dart` over `test/fixtures/gradle/`
- [x] Q&A blocks for init / compare / debug-step in `docs/guides/build_and_config.md`

### Open

- [ ] Multi-dex determinism: d8 part-file count can vary between runs (tracked
      under the ADR-0006 phase)
