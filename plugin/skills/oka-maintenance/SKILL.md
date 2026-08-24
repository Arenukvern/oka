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
  version: 1.1.0
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
4. **Test**: `make test` (dart test) + `make lint` (dart analyze).
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
| Launcher icons | `lib/src/build/launcher_icon.dart` |
| Extra assets / deeplinks | `lib/src/pipeline/steps/asset_steps.dart` |
| Manifest/host codegen | `lib/src/build/host_codegen.dart` |
| AAB layout & signing | `lib/src/build/aab_layout.dart`, proto link in `toolchain.dart` |

## Device validation loop

```bash
export ANDROID_SDK_ROOT=~/.oka/android-sdk
cd example && dart ../bin/oka.dart build apk
adb install -r .oka_cache/build/debug/app-debug.apk
adb shell am start -n com.example.example/.MainActivity
adb logcat -d -b crash | grep com.example
```

Missing class at runtime → add to `kKnownClassArtifacts`
(`dependency_suggest.dart`) if generally useful; project-specific deps go in
the project's `oka.yaml` `pipeline.extra_deps`.

AAR payload not landing in APK → check `payload/` dir next to the cached
classes.jar; local AARs extract under `<build_dir>/local_aars/<name>/`.

APK inspection:
```bash
unzip -l app.apk | grep <pattern>                       # entries
aapt2 dump badging app.apk                              # manifest/icon info
aapt2 dump xmltree --file AndroidManifest.xml app.apk   # compiled manifest
```

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

## Install

```bash
npx skills add arenukvern/skill_steward --skill oka-maintenance
```

## Sources

See [references/sources.md](references/sources.md).
