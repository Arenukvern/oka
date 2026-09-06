---
title: Design FAQ
---

# Design FAQ

Why oka is built the way it is. How-to lives in the
[build & configuration guide](build_and_config.md); settled decisions live
in [`docs/decisions/`](../decisions/index.md).

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

**Q: If oka goes multi-platform someday, what carries over?**
A: The contracts, not the code. `oka_core` is already platform-agnostic
(pipeline, typed artifacts, composition root, `okaRun`); a platform is a new
`PlatformPipeline` package selected by `--platform`, and the agent surface
(explain/compare/doctor/debug step) composes whatever pipelines exist. That's
why the design law bans platform detail in core — see
[why oka matters](../start_here/why_this_repo_matters.md) for the expansion
criteria.

**Q: Why sort d8 inputs and zip entries?**
A: Dependency resolution runs in parallel, so jar order varied between runs —
and d8 partitions classes into `classesN.dex` in argument order, making the
multi-dex split (part count + content) non-reproducible. Sorting d8 inputs
and writing zip entries in sorted path order makes artifacts byte-for-byte
reproducible, which is what `oka compare` gates on. Enforced by
`test/determinism_test.dart`.

**Q: Why was the Rust/cargo-apk hybrid removed?**
A: It rewrote the shared `rust_wrapper/Cargo.toml`, corrupting shared state,
and duplicated packaging logic, so ADR-0001 demoted it. With zero remaining
usage and a permanently failing quarantine test, ADR-0009 removed it entirely
— the no-Gradle pipeline is the only build path.

## Toolchain & caching (ADR 0013)

**Q: Why is the cache a contract instead of oka behavior?**
A: Because "oka has a cache" is how caches become black boxes — opaque keys,
undocumented layout, no way to purge or share. ADR-0013 makes the store a
small interface (`ArtifactStore` + `ContentKey`) with a boring default: a
plain directory with human-decodable layout (`~/.oka/store/aapt2/8.0.2-<hash>/`)
inspectable with `ls` and `find`. Sharing rule: **inputs** (SDKs, Maven
artifacts, emulator images) are shared and `OKA_CACHE`-pointable; **outputs**
(dex, APKs) stay per-project in `buildDir/` — cross-machine output caches are
where nondeterminism lives.

**Q: Why is env-var precedence resolution *data*?**
A: Precedence used to be encoded in `SdkLocator` control flow — invisible,
untestable, and unprintable. As an ordered resolution policy (explicit
config → env vars → oka-managed roots → system) it becomes a value: `oka
doctor` prints it, tests assert it, and a project can override the order
without editing oka. Related law: **no stdin in any build path** —
interactive prompts are agent-hostile; steps fail with a named fix instead.

**Q: Are Google Play and Huawei separate platforms?**
A: No — distribution targets are not platforms (ADR-0013). Play, AppGallery,
and RuStore builds are one Android application composed differently: a
target = a build-variant composition (e.g. no GMS deps for Huawei) plus a
publish tail. Targets live in separate packages (`oka_play`, `oka_huawei`,
…) over the same pipeline kernel; store APIs and credential handling are
deferred to their own ADR (0014).

## Configuration

**Q: Why extension types for config models?**
A: They give type-safe views over decoded JSON with zero runtime allocation —
no wrapper objects in hot build paths.

**Q: Why YAML (`oka.yaml`) rather than reusing `build.gradle`?**
A: One declarative, pub-style file covers both Flutter and Android settings;
Gradle files are never parsed — oka does not read them at all (ADR-0012).

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

**Q: Why extract AAR natives/res instead of dexing classes.jar only?**
A: An AAR is a fat library: classes.jar alone misses `jni/<abi>/*.so` (crash on
System.loadLibrary) and `res/values` attrs (aapt2 resource mismatches). Since
extraction is just zip entry copying, the cost is trivial versus the runtime
failures it prevents; both Maven AARs and local `pipeline.local_aars` share
the same `extractAarPayload` path.

## Packaging

**Q: Why must `resources.arsc` be stored uncompressed?**
A: Android 11+ rejects installs (-124) when resources.arsc is compressed or
not 4-byte aligned for targetSdk ≥ 30. `zipStagingToApk` marks it STORED and
zipalign runs with `-p 4`; found via real-device install failure.

**Q: Why hand-assemble AABs instead of using bundletool? (ADR 0004)**
A: The bundle is just a zip with a proto-format `base/` module; reusing the
existing pipeline with one aapt2 flag (`--proto-format`) keeps oka's zero-extra-
tool dependency and lets it structurally validate its own output. Bundles sign
with jarsigner v1 because apksigner doesn't sign bundles.

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

## Dev loop (ADR 0010)

**Q: Why does `oka dev` delegate the reload machinery to flutter_tools?**
A: The boundary is contract type, not brand loyalty. `flutter assemble` (the
build delegate) is a stable batch CLI; the resident kernel compiler behind hot
reload is an internal flutter_tools contract that changes with the engine.
Reimplementing it buys near-zero user-facing value today and permanent
version-lock cost. ADR-0010 delegates the Dart VM session over the
machine-readable daemon protocol (`--machine`) while oka owns build →
install → launch and the entire event/UX surface — including the headless,
agent-usable control path a TUI cannot provide.

**Q: Why not just exec `flutter attach`?**
A: Its default interface is a human TUI keystroke loop — unusable by agents,
which is oka's primary audience (see [why this repo matters](../start_here/why_this_repo_matters.md)).
Machine mode gives agents a first-class path; the TUI remains available as a
human escape hatch (`oka dev --tui`). Owning the compiler instead is gated
behind a new ADR with measured evidence (ADR-0010 §6).

## Gradle conversion (ADR 0012)

**Q: Why doesn't `oka init` convert `build.gradle` automatically?**
A: Converting Gradle means understanding plugins, conditionals, and custom
logic — a judgement task, not a parsing task. oka's primary user is an AI
agent driving the build; that agent converts `build.gradle` → `oka.yaml`
itself, with full repo context and in reviewable diff space. Embedding an
LLM client inside the build tool would add API keys, network calls, and
non-determinism to a build system — the opposite of what oka stands for.

**Q: What does `oka init --yaml` do with an existing Gradle config?**
A: It prints a precise porting checklist (package id, SDK levels, ABIs,
dependencies, signing) and scaffolds a default `oka.yaml`. Validate with
`oka explain`; missing classes are diagnosed by `oka build apk` with a
ready-to-paste dependency suggestion (see Dependencies Station in the build
guide).
