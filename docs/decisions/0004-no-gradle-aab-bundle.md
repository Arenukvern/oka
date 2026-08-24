# 0004 — No-Gradle AAB via hand-assembled bundle (aapt2 proto-format, no bundletool)

- **Status:** accepted
- **Date:** 2026-08-24
- **Decision-makers:** Anton, oka agent

## Context

`oka build aab` currently accepts the flag but falls back to the APK pipeline
with a warning. Play Store delivery needs a real App Bundle: proto-format
manifest (`AndroidManifest.xml` as protobuf), `resources.pb`, compiled `res/`,
and per-module dex/lib/assets under a `base/` module.

## Considered options

- **A. Hand-assemble**: reuse the existing APK pipeline; swap the resource link
  to `aapt2 link --proto-format`, stage a `base/` layout, zip, sign with
  `jarsigner` (bundles use v1 JAR signing; `apksigner` does not sign bundles).
- **B. bundletool**: download Google's `bundletool.jar`, feed it the same
  inputs, let it build/sign the bundle. Adds a large Java tool dependency, a
  download/bootstrap path (`oka get`-style), and a second packaging authority
  whose output oka cannot structurally validate or control.

## Decision

Chosen option: **A**, consistent with ADR-0001 (oka owns packaging with SDK
tools only). The APK and AAB pipelines share steps up to dexing; they diverge at
resource linking (proto vs binary format) and packaging (`base/` module zip +
jarsigner vs staging + zipalign + apksigner). Users may still use bundletool
locally to expand/install from an oka-built `.aab`; oka itself never requires it.

Consequences:

- `aapt2_commands.dart` gains a proto-format link argv builder.
- New `aab_layout.dart` mirrors `apk_layout.dart` (staging + validation).
- Pipeline gains proto compile/dex, bundle package/sign, and bundle validation
  steps; `defaultAabPipeline` composes them.
- Debug AABs are for local verification only — Play requires release/AOT
  bundles; both modes are produced identically otherwise.
- Signing is v1-only (jarsigner) which is what bundletool/Play accept for
  `.aab`; upload keys are managed by Play after upload.

**Authoritative source:** `lib/src/build/aab_layout.dart`,
`lib/src/pipeline/default_pipeline.dart`, this file.
