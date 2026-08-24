# 0001 — No-Gradle default build path; demote cargo-apk hybrid

- **Status:** accepted
- **Date:** 2026-08-24

## Context

Early oka explored three build paths: direct Android SDK tools,
pure native-Android shell pipeline, and a cargo-apk + Rust NativeActivity
hybrid. The hybrid rewrote shared `rust_wrapper/Cargo.toml`, corrupting state,
and Gradle fallback masked failures of oka's own pipeline.

## Decision

1. The default `oka build apk` path is the no-Gradle orchestrator:
   `flutter assemble` → engine artifact extraction → host codegen → AndroidX
   resolve → `aapt2`/`javac`/`d8` → package → sign. It must never report
   success by shelling out to `flutter build apk`/Gradle.
2. The Rust/cargo-apk hybrid is demoted to experimental (`--flutter` opt-in);
   default builds never mutate `rust_wrapper/Cargo.toml`.
3. Phase completion requires test evidence in `docs/PHASE_CHECKLIST.md`.

## Consequences

- Faster, deterministic builds; clear failure modes via `oka doctor`
- Plugin support limited to what plugin discovery + registrant codegen can handle
- Native-complex plugins fail loudly instead of silently falling back

**Authoritative source:** `lib/src/build/flutter_apk_builder.dart`, `test/phase0_no_gradle_fallback_test.dart`
