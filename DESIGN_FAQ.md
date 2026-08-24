# DESIGN_FAQ — Oka

Why oka is built the way it is. How-to lives in `DX_FAQ.md`; settled decisions
live in `docs/decisions/`.

## Build path

**Q: Why replace Gradle instead of wrapping it?**
A: Gradle adds 30s+ configuration/daemon overhead per build that Flutter
Android builds don't need. Oka invokes `flutter assemble` + SDK tools directly,
targeting incremental builds 3–5x faster. Trade-off: no full Gradle plugin
compatibility (see ADR 0001).

**Q: Why must the default path never fall back to `flutter build apk`?**
A: A silent fallback would hide gaps in oka's own pipeline and make success
non-deterministic. Missing-tool failures surface via doctor-oriented errors so
agents can remediate. Enforced by `test/phase0_no_gradle_fallback_test.dart`.

**Q: Why is the Rust/cargo-apk hybrid demoted?**
A: It rewrote the shared `rust_wrapper/Cargo.toml`, corrupting shared state,
and duplicated packaging logic. It stays as an opt-in experiment; default
builds never touch its Cargo.toml.

## Configuration

**Q: Why extension types for config models?**
A: They give type-safe views over decoded JSON with zero runtime allocation —
no wrapper objects in hot build paths.

**Q: Why YAML (`oka.yaml`) rather than reusing `build.gradle`?**
A: One declarative, pub-style file covers both Flutter and Android settings;
Gradle files are read as text only during AI conversion, never parsed.

## AI conversion

**Q: Why send Gradle files to an LLM as text instead of parsing them?**
A: Gradle is a programming language with plugins and conditionals; a parser
would be a maintenance sink. The AI extracts the common-case subset, results
are cached for offline reuse, and output lands in reviewable `oka.yaml`.

**Q: Which AI providers?**
A: Apple Foundation Models on macOS with Gemini fallback — swappable behind
the conversion service in `lib/src/ai/`.
