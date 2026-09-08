---
name: oka-maintenance
description: >-
  Maintains the oka no-Gradle Flutter Android build system — pipeline steps,
  dependency recovery, icons/assets/deeplinks fast-settings, docs sync, and
  device validation. Use when changing oka's lib/src/pipeline or lib/src/build
  code, adding oka.yaml settings, fixing missing-class crashes, updating
  FAQs/ADRs after oka changes, or validating builds on an Android device.
license: MIT
metadata:
  version: 1.3.0
  author: Arenukvern
compatibility:
  - android-sdk
  - flutter
  - dart
---

# Oka maintenance

Oka is a Dart CLI replacing Gradle for Flutter Android builds. Repo map:
`AGENTS.md`. Behavior SSOT is code + tests; docs link, never paraphrase.

## When to use / not use

**Use:** pipeline or build-code changes, new `oka.yaml` settings, missing-class
crash recovery, docs sync after behavior changes, device validation.

**Not use:** end-user Flutter app questions (point at
https://docs.page/arenukvern/oka), iOS/desktop targets (out of scope), or
Gradle debugging (oka has none).

## Workflow

1. **Locate** the change surface (see Map below).
2. **Check invariants** before coding (Non-negotiables).
3. **Implement** following existing step/toolchain patterns.
4. **Test**: `just test` (dart test) + `just lint` (dart analyze).
5. **Validate on device** when behavior changes packaging or runtime deps.
6. **Sync docs** per the rules below — why → design FAQ / ADR, how → build guide.

## Non-negotiables (from AGENTS.md)

- Default path never shells out to `flutter build apk`/Gradle as success.
- Never mutate shared `rust_wrapper/Cargo.toml`.
- Design forks → decision checkpoint + ADR (`docs/decisions/`) before coding.
- `resources.arsc` must be STORED (uncompressed) + zipalign `-p 4` — Android
  11+ rejects installs otherwise. See `lib/src/build/apk_layout.dart`.

## Map

| Change | Location |
|---|---|
| Pipeline steps | `lib/src/pipeline/steps/*.dart` |
| Step contracts / state | `lib/src/pipeline/pipeline.dart` |
| Tool invocations (aapt2/javac/d8/sign) | `lib/src/pipeline/toolchain.dart` |
| Default step order + YAML overrides parsing | `lib/src/pipeline/default_pipeline.dart` |
| Dependency set + Maven cache | `lib/src/build/dependency_cache.dart` |
| AAR payload extraction (natives/res) | `extractAarPayload` in `dependency_cache.dart`; local AARs via `_LocalAarsStep` in `default_pipeline.dart` |
| Crash-class → artifact mapping | `lib/src/build/dependency_suggest.dart` |
| Gradle `.module` metadata parsing (metadata-only runtime deps, e.g. camera → atomicfu) | `parseModuleRuntimeDependencies` in `lib/src/maven_resolver.dart` |
| Manifest spec (typed surface + `manifest_elements` escape hatch) | `lib/src/manifest_spec.dart`, rendering in `lib/src/build/host_codegen.dart` |
| Launcher icons (name/manifest_ref, user-icon precedence) | `lib/src/build/launcher_icon.dart`, skip logic in `pipeline/steps/host_steps.dart` |
| Config sources (oka.yaml / pubspec `oka:` / Dart entrypoint) | `loadOkaYaml` in `packages/oka_core/lib/src/oka_run.dart` |
| Artifact diff gate | `lib/src/compare.dart` + `oka compare` |
| Device smoke test | `oka launch` (`packages/oka/lib/src/cli/launch_command.dart`) |
| DEX symbol check | `oka debug dex <apk> --find <Class>` |
| Launcher icons | `lib/src/build/launcher_icon.dart` |
| Extra assets / deeplinks | `lib/src/pipeline/steps/asset_steps.dart` |
| Manifest/host codegen | `lib/src/build/host_codegen.dart` |
| AAB layout & signing | `lib/src/build/aab_layout.dart`, proto link in `toolchain.dart` |

## Device validation loop

```bash
export ANDROID_SDK_ROOT=~/.oka/android-sdk
cd example && dart ../packages/oka/bin/oka.dart build apk
oka launch                                   # install newest APK + launch + logcat scan
oka debug dex .oka_cache/build/debug/app-debug.apk --find some.pkg.Class
oka compare gradle-built.apk .oka_cache/build/debug/app-debug.apk
```

`oka launch` clears logcat, installs, launches, waits, then scans for failure
signatures (FATAL EXCEPTION, NoClassDefFoundError, GeneratedPluginRegistrant
failure, `Error registering plugin`, channel-error). Exit 1 + signature list =
regression. `oka debug dex` catches missing runtime classes BEFORE installing.

Missing class at runtime → add to `kKnownClassArtifacts`
(`dependency_suggest.dart`) if generally useful; project-specific deps go in
the project's `pipeline.extra_deps`. Metadata-only Gradle module deps
(`.module`) parse automatically — extend `parseModuleRuntimeDependencies`
tests if a new variant shape appears.

AAR payload not landing in APK → check `payload/` dir next to the cached
classes.jar; local AARs extract under `<build_dir>/local_aars/<name>/`.

APK inspection:
```bash
unzip -l app.apk | grep <pattern>                       # entries
aapt2 dump badging app.apk                              # manifest/icon info
aapt2 dump xmltree --file AndroidManifest.xml app.apk   # compiled manifest
```

## Release train

Releases are automated via release-please; `VERSION` is the single version
source. Golden path:

1. Merge PRs to `main` with conventional commit titles (`feat:`, `fix:`,
   `docs:`).
2. release-please opens a **Release PR** (`chore: release X.Y.Z`). The
   `release_pr_sync_versions.yml` workflow runs `tool/release/sync_version.sh`
   and commits drift to pubspec + plugin manifests automatically.
3. Run `just check-contracts` locally, review, merge.
4. Tag `vX.Y.Z` is created by release-please → `pub_publish.yml` publishes to
   pub.dev (asserts tag == VERSION first).

Manual fallback when automation is blocked:

```bash
bash tool/release/sync_version.sh --version X.Y.Z   # or: just sync-version
# edit CHANGELOG.md under [X.Y.Z]; bump .release-please-manifest.json
just check-contracts
git commit -am "chore: release X.Y.Z" && git tag vX.Y.Z && git push --tags
```

Version touchpoints that must match `VERSION`: `pubspec.yaml`,
`plugin/.cursor-plugin/plugin.json`, `plugin/.codex-plugin/plugin.json`,
`plugin/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`
(`plugins[0].version`). Adding a new touchpoint = update `sync_version.sh`,
`check_version_sync.sh`, and `release-please-config.json` `extra-files`
together.

## Skill distribution

Canonical skills live in `plugin/skills/`; root `skills` symlink exposes them
to `npx skills add Arenukvern/oka`. When editing a skill, update **both** the
plugin copy and your installed copy (or reinstall via
`npx skills add Arenukvern/oka --skill oka-maintenance`).

## Docs sync rules

After any change:

| Change type | Update |
|---|---|
| Internal trade-off / architecture | `docs/guides/design_faq.md` Q&A (≤3 sentences) and/or new ADR |
| Public API / usage / config key | `docs/guides/build_and_config.md` (copy-paste valid block) |
| Settled strategic decision | `docs/decisions/NNNN-*.md` + index row |
| Phase-level feature completion | `docs/PHASE_CHECKLIST.md` evidence table |

No duplication between files — link instead. Source-contract tests (tests that
read source text) must follow moved code: update their file paths when
refactoring.

Docs are published via docs.page (`docs.json` sidebar): when adding a doc file,
add it to the sidebar in `docs.json` too.

## Common failure modes

- **Editing a step but testing the wrong pipeline**: default order lives in
  `default_pipeline.dart`; the example app composes it via `oka.yaml`, not
  code. Verify with `cd example && oka build apk`.
- **Adding a dep to the embedding set when it should be project-local**:
  `flutterEmbeddingAndroidXDeps()` ships to *every* host — prefer
  `pipeline.extra_deps` unless every Flutter app needs it.
- **Forgetting source-contract tests**: tests under `test/` read source text;
  moving code without updating their paths breaks CI even when behavior is fine.
- **Signing assumptions**: APKs sign with apksigner; AABs sign with jarsigner
  v1 (apksigner does not sign bundles). Debug keystore by default — never
  commit release keystores.
- **Hardcoding app-specific knowledge in oka**: dependency companions,
  icon resource names, manifest entries — all must stay configurable
  (IconConfig `name`/`manifest_ref`, `manifest_elements`, `extra_deps`).
  A fix that only works for one app is not fixed (see
  `docs/guides/gradle_migration.md` for the general mapping).
- **`filterRuntimeJars` version ties**: KMP root jars (`atomicfu`) carry no
  JVM classes — the platform-suffixed variant (`-jvm`/`-android`) must win
  ties or d8 silently drops the classes.
- **Stale generated res**: icon/theme artifacts from earlier builds survive
  in `.oka_cache/build/<mode>/res` — cleanup logic lives in host-steps icon
  staging; clean the build dir when changing generation logic.
- **Device-side**: `unauthorized` = accept the USB prompt;
  `INSTALL_FAILED_UPDATE_INCOMPATIBLE` = signing mismatch — sign with the
  same key, NEVER uninstall an app holding user data;
  `adb: no devices` mid-session = flaky USB, retry with `adb kill-server`.

## Install

```bash
npx skills add arenukvern/skill_steward --skill oka-maintenance
```

## Sources

See [references/sources.md](references/sources.md).
