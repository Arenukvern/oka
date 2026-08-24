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

## Pipeline architecture (ADR 0002)

**Q: Why a composable step pipeline instead of one builder method?**
A: The monolithic `FlutterApkBuilder.build()` made every extension a fork:
adding one dependency or flag required editing oka's source (four consecutive
device crashes proved the cost). Steps (`BuildStep.run(ctx, state)`) make the
pipeline data users can extend, and stages testable in isolation.

**Q: Why `PipelineState` as a mutable blackboard instead of immutable step
outputs?**
A: Build steps form a linear chain where each consumes several upstream
artifacts; threading a growing tuple through signatures would churn every step
on every addition. The blackboard keeps step signatures stable; typed getters
prevent key typos.

**Q: Why both YAML fast-settings AND a Dart composition API?**
A: YAML covers the 90% case (extra deps, icons, deeplinks, assets) without
Dart code; full `Pipeline` composition covers reordering/replacing steps.
Precedence is strict: defaults < oka.yaml < user-built pipeline.

**Q: Why is dependency resolution a fixed set plus escape hatch, not full
transitive resolution?**
A: Full Maven transitive resolution needs POM graph walking and version
conflict mediation — a Gradle-sized problem. The fixed embedding set covers
Flutter hosts; `pipeline.extra_deps` handles gaps. Recovery suggestions
(`dependency_suggest.dart`) close the loop when the set misses runtime classes.

## Packaging

**Q: Why must `resources.arsc` be stored uncompressed?**
A: Android 11+ rejects installs (-124) when resources.arsc is compressed or
not 4-byte aligned for targetSdk ≥ 30. `zipStagingToApk` marks it STORED and
zipalign runs with `-p 4`; found via real-device install failure.

**Q: Why vector-first launcher icons without PNG generation?**
A: Adaptive icons (API 26+) are pure XML — VectorDrawable foreground + color
background need no image tooling or binary assets, keeping oka's zero-dep
packaging path. Raster density buckets only matter for pre-API-26 (<2% of
devices); that's an opt-in future extension requiring an image codec.

**Q: Why does asset staging run as a separate step after flutter-assemble?**
A: pubspec-declared assets come from `flutter assemble`; generated files,
raw configs, and per-flavor bundles don't. A post-assemble merge point lets
users inject anything into flutter_assets without touching Flutter tooling.

## Dependency recovery

**Q: Why an offline class→artifact table instead of live search?**
A: Runtime crashes name exact classes (`Landroidx/collection/SimpleArrayMap;`);
a curated prefix table resolves them instantly offline with high confidence.
Cache-scan fallback covers unknown packages using already-downloaded artifacts.
Network search would add latency and nondeterminism to error paths.

## AI conversion

**Q: Why send Gradle files to an LLM as text instead of parsing them?**
A: Gradle is a programming language with plugins and conditionals; a parser
would be a maintenance sink. The AI extracts the common-case subset, results
are cached for offline reuse, and output lands in reviewable `oka.yaml`.

**Q: Which AI providers?**
A: Apple Foundation Models on macOS with Gemini fallback — swappable behind
the conversion service in `lib/src/ai/`.
