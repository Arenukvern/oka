# Kernel toolchain knowledge (Dart 3.13.2 era)

Everything here was established empirically (see
`docs/evidence/deferred-patch-units-spike-2026-10-01.mdx`). Re-verify on SDK
bumps: run `tool/gate.sh all` — if a gate fails after an SDK upgrade, start
with §1 and §5.

## 1. Metadata is invisible unless you opt in

The kernel binary format carries VM metadata subsections (TFA products:
direct-call, inferred-type, table-selector, unboxing-info, loading-units,
...). Rules:

- Plain `BinaryBuilder` and `loadComponentFromBytes` **drop every metadata
  subsection silently**. Use `BinaryBuilderWithMetadata`.
- Only subsections whose repository is registered on the component before
  reading are kept: `component.metadata[repo.tag] = repo` for all twelve
  (`pkg/vm/lib/metadata/*.dart`; call-site-attributes lives under
  `pkg/vm/lib/modular/metadata/`).
- `disableLazyReading: true` is required for mappings to materialize for
  writing.
- Verify losslessness by re-reading your own output and comparing mapping
  sizes (see `tool/kernel_roundtrip.dart`).

## 2. The SDK hash gates C++ consumption

`expectedSdkHash` is a compile-time `const String.fromEnvironment('sdk_hash')`
in `pkg/kernel/lib/binary/tag.dart`. Official gen_kernel bakes the release
short commit hash; a from-source compile writes `0000000000`, and gen_snapshot's
C++ misbehaves (e.g. "Missing table selector metadata"). Always run
kernel-consuming tools with `-Dsdk_hash=<10-char hash>` — carry the hash from
the input dill (bytes 8..18) or from `git -C $CHECKOUT rev-parse --short=10 HEAD`.

## 3. Post-TFA dill rewriting is unsupported

A byte-level rewrite of an AOT-lowered dill (post-gen_kernel) is lossless on
the Dart side but **gen_snapshot rejects it** ("Missing table selector
metadata") — the C++ reader requires the original serialization context.
Transforms must run *inside* the pipeline, between the CFE compile and
serialization — the hook in `tool/gate_pipeline.dart`
(`kernelForProgram` → hook → `runGlobalTransformations` → `BinaryPrinter`).

## 4. Deferred loading representation

- `LibraryDependency.flags & DeferredFlag (1 << 1)` — a plain mutable field
  in `pkg/kernel/lib/src/ast/libraries.dart`. There is no `deferred` keyword
  remnant in the AST layer.
- Use sites: `LoadLibrary` (triggers load) and `CheckLibraryIsLoaded`
  expression nodes.
- gen_snapshot partitions loading units from those dependency flags; loading
  units are ELF-only on emission (`--loading_unit_manifest` + `--elf`); Mach-O
  refuses the path outright ("deferred loading not implemented for Mach-O").
- The VM verifies program identity at `loadLibrary()`: a foreign unit file
  raises `DeferredLoadException: ... different program than the main loading
  unit`. Whole-revision swaps only.
- The SDK's own `deferred_loading.transformComponent` runs in
  `runGlobalTransformations` — the deferredize hook slots in before it.

## 5. Pipeline gotchas (`tool/gate_pipeline.dart`)

- `getTarget('vm', ...)` returns null until `installAdditionalTargets()`
  (`package:vm/modular/target/install.dart`) runs.
- Set `CompilerOptions.sdkSummary` (platform dill) but NOT `sdkRoot` — setting
  both makes the CFE recompile the SDK from source.
- Pass `packagesFileUri` explicitly; the walk-up discovery is unreliable under
  containers/mounts.
- Entry URIs must be absolute (`Uri.file(File(p).absolute.path)`).
- Kernel/vm/front_end and friends resolve via a *generated* package_config
  (checkout packages + a pub-solved shim for third-party deps — per-package
  "newest in cache" resolution produces incompatible sets). See
  `tool/gate_g1b_g2.sh` step 2.
- `dart <unlinked.dill>` fails for apps importing dart:io etc. —
  frontend_server full dills are app-only; run apps from source or link the
  platform.

## 6. frontend_server protocol (dev/live lane)

Snapshot: `bin/snapshots/frontend_server_aot.dart.snapshot` — run via
`dartaotruntime`, `--incremental --sdk-root=<sdk>/` (no `--aot`; incremental
AOT is refused). Line protocol on stdin:

```
compile <entry>                                  -> result <boundary-key>
<lib list>                                       -> <boundary-key> <full.dill> 0
recompile <entry> <boundary-key>                 -> result <new-boundary-key>
<invalidated file uri>...                        -> <new-key> <delta.incremental.dill> 0
<boundary-key>
accept / quit
```

Delta dills are what a live reload consumes — but the wire path is the
**private `_reloadKernel {isolateId, kernelFilePath}`** (the VM reads the
delta file with its own file callbacks). The public `reloadSources` has NO
kernel-bytes parameter — unknown params are dropped silently — and without
a root-lib binary it recompiles from source via the kernel isolate. And the
fs's incremental `recompile` output is NOT a valid reload payload: the VM's
`DeltaProgram::ReadFromTypedData` refuses it (RELEASE_ASSERT crash);
compile the delta with `tool/gate_pipeline.dart --delta` instead (plain
`writeComponentFile` parses on all 3.13.x VMs measured). Note: the app
runs from *source*; the frontend_server's full dill cannot run standalone
(unlinked).

## 7. Containers

Host and container dart versions must match exactly. Mount host trees at
identical absolute paths (repo, dart-sdks checkout, pub cache) so generated
package_configs resolve unchanged. Containers lack python3/`strings`/binutils
and pub cache — generate package_configs, use `grep -a`, and run helper dart
scripts with the JIT `dart` (not `dartaotruntime`, which runs only AOT
snapshots).

## 8. Real-app lessons (last_answer gates, 2026-10-02)

- **Loading units are dominator-based, not closure-based.** The VM's
  `computeLoadingUnits` (pkg/vm `transformations/deferred_loading.dart`)
  builds a dominator tree over ALL dependencies (imports AND exports) and
  roots a unit wherever every root path crosses a deferred edge. Shared
  libraries (imported by two units, or exported by a root barrel) stay in
  the root unit. A feature with several outside seams fragments into one
  unit per seam.
- **Synthetic deferred entry imports are mandatory; deferred export flags
  alone don't split.** The C++ backend keys units off deferred imports
  reachable from the entry.
- **AOT part loads are lazy.** Flags-only partitioning crashes at the first
  cross-unit call (bus error into an unmapped part). `await LoadLibrary`
  guards in main are required — hence async main.
- **Sync mains are refused.** `await` in a sync main compiles but aborts the
  AOT loader at teardown; flipping `asyncMarker` post-CFE crashes the same
  way (async lowering happens in the CFE). The transform errors with
  "unit load guards need an async main".
- **Mid-pipeline transforms re-open seams.** `dart:mixin_deduplication`
  synthesizes libraries with fresh non-deferred edges into unit members.
  oka therefore runs the `runGlobalTransformations` sequence itself
  (`runGlobalTransformationsWithUnits` in `tool/gate_pipeline.dart`) and
  re-flags cross-boundary edges right before `deferred_loading`.
- **Flutter patched SDK needs `--target=flutter` and a matching checkout.**
  The patched platform dill lacks the stock VM target's extra required
  libraries (`dart:cli`, `dart:_compact_hash`) — use `OKA_TARGET=flutter`.
  `-Dsdk_hash` must match the flutter dart version's release hash
  (clone `dart-sdks/sdk-<version>`, `git rev-parse --short=10`).
  `languageVersion` entries in the pipeline package_config must be
  major.minor, not full versions. Cross manifests: the engine's
  android-arm64 `gen_snapshot` runs on the mac host
  (`artifacts/engine/android-arm64-release/darwin-x64/gen_snapshot`).
- **JIT lane SDK split.** The 3.13.2 frontend_server crashes in
  `ForInLowering` on some real app code; flutter 3.13.4's fs works
  (`--target=flutter`, patched SDK). The 3.13.4 VM service drops
  params-bearing JSON-RPC requests (even 103-byte `reloadSources` with only
  `isolateId` reports `params:{}`) — run the app under the stock 3.13.2 VM
  and the fs on 3.13.4; kernel format is compatible across 3.13.x. DDS
  (in front of `flutter run`) does NOT have the params problem.
- **The stock fs delta is full-component sized at ANY recompile root.**
  Recompile-from-entry *and* re-rooting the recompile at the patch unit's
  library both re-serialize every transitive dependent of the patch —
  measured 135,382,896 bytes on last_answer. `--no-link-platform` and
  `--enable-experiment=alternative-invalidation-strategy` do not shrink it.
  A small delta must be compiled outside the incremental session.

## 9. Per-unit reload lane (flutter run + DDS, 2026-10-02)

The wire facts behind `tool/gate_g3_real_flutter.sh` (all verified in VM
source `runtime/vm/service.cc` / `kernel_isolate.cc` / `isolate_reload.cc`):

- **`reloadSources` drops unknown params silently.** Its params are `force`,
  `pause`, `rootLibUri`, `packagesUri` — there is no kernel-bytes parameter.
  A `kernelBytes` payload is never read.
- **"Error while starting Kernel isolate task" = no kernel isolate, not a
  size limit.** Without a root-lib binary the reload recompiles from source
  via `KernelIsolate::CompileToKernel`; `KernelIsolate::Start()` fails when
  the embedder didn't set `start_kernel_isolate` — the flutter embedder
  never does. (The stock `dart` VM does, which is why source-side reload
  works there.)
- **`_reloadKernel {isolateId, kernelFilePath}`** is the path that consumes
  a delta kernel file: the VM `file_read`s it and loads it as the reload
  delta (`IsolateGroup::ReloadKernel` → `DeltaProgram::ReadFromTypedData`).
  Needs the app's library tag handler installed (flutter's is). Desktop/dev
  lane: the file must be readable by the app process (mind macOS app
  sandbox containers on device-shaped builds).
- **Unit-sized delta:** compile the patch unit's library as the reload root
  with `tool/gate_pipeline.dart --delta` — `kernelForModule([unitLib])`
  (`kernelForProgram` returns null for library entries: no `main`),
  dart:\* external via sdkSummary, component pruned to the unit's file so
  everything else is a canonical-name reference resolved against the loaded
  program. No global transforms (JIT delta). 11KB on last_answer.
- **Compile-time env for the delta subprocess:** `DART_SDK_SUMMARY` = the
  flutter patched-SDK `platform_strong.dill` of the flutter that runs the
  app, `DART_PACKAGES_CONFIG` = the app's `.dart_tool/package_config.json`
  (import URIs must match what the app was compiled with), `OKA_TARGET=
  flutter`. The tool process itself runs on the checkout kernel stack
  (`tool/pipeline_packages_config.sh` builds that package_config).

## 10. Native per-unit AOT platform facts (2026-10-02)

- The snapshot-kind names in 3.13 are `app-aot-elf`, `app-aot-macho-dylib`,
  `app-aot-pecoff-obj` (there is no `app-aot-macho`). The earlier
  "Mach-O refuses the manifest" probe used an invalid kind name; the REAL
  refusal for the valid macho kind + manifest is
  `error: deferred loading not implemented for Mach-O`.
- `app-aot-elf --loading_unit_manifest` splits on **every** host measured:
  mac host (`<dart-sdk>/bin/utils/gen_snapshot`), linux containers, and the
  flutter cross binaries (android-arm64, ios) — the latter emit
  `base.so` + `base.so-N.part.so`.
- Part files load WITHOUT the host dynamic linker: the standalone embedder
  installs `Loader::DeferredLoadHandler` (runtime/bin/main_impl.cc), which
  reads `<script-url>-<unit-id>.part.so` next to the base snapshot;
  `Snapshot::TryReadAppSnapshot` falls back to the VM's own `Dart_LoadELF`.
  Any embedder can take over via `Dart_SetDeferredLoadHandler` — Flutter's
  Android deferred-components seam.
- Cross gen_snapshots verify the dill's sdk hash: a 3.13.2-built dill in a
  3.13.4 gen_snapshot fails with a bare `ApiError`. Build each dill from
  the checkout matching the consumer (`tool/gate_aot_platforms.sh` does).
- Building the stock android runtime is supported by the checkout itself:
  `tools/build.py --os=android --arch=arm64` (gclient-synced checkout;
  depot_tools + the pinned toolchains). No fork involved.

### Android stock runtime (per-unit AOT run leg)

1. `gclient sync` a fresh clone of the target tag with the canonical
   layout: `.gclient` in the parent, solution `name: "sdk"`, `url: None`,
   checkout at `<root>/sdk` — gclient materializes entries under the
   SOLUTION dir, so the name is load-bearing.
2. `ln -s <ndk> sdk/third_party/android_tools/ndk` — the existing machine
   NDK suffices; `download_android_deps` (the multi-GB flutter/android cipd
   package) is unnecessary.
3. gn-gen with `dart_use_compressed_pointers=true` — must match the
   snapshot (flutter's arm64 gen_snapshot uses compressed pointers;
   mismatch is rejected at load with the full config printed). build.py has
   no gn-args passthrough — call
   `buildtools/<host>/gn gen <out> --args='...'` directly, then
   `buildtools/ninja/ninja -C <out> dartaotruntime_product`.
4. Deploy: push runtime + `app.so` + `app.so-N.part.so`, chmod +x, run —
   `Loader::DeferredLoadHandler` resolves parts relative to the snapshot
   argv path.

## 11. Live session API (`oka_update`, 2026-10-02)

The reload lanes above are productized as a declarative session:
`LivePatchSpec` (unit, find/replace patches, targets, probes — JSON or
in-code) → `LivePatchSession` (compile via injected `UnitDeltaCompiler` =
`tool/gate_pipeline.dart --delta`, apply per target, verify probes, receipt)
→ `LivePatchReceipt` + `LivePatchEvent` stream. Driver:
`tool/live_e2e.dart` (env: `LIVE_SPEC`, `LIVE_ROOT`, `LIVE_DELTA_*`,
`LIVE_RECEIPT`). Gate: `tool/gate_live_e2e.sh [mac-vm|linux-docker|android|web|all]`.

Wire facts encoded in `oka_update/lib/src/live/`:

- Dart 3.13 renamed DevFS RPCs: `_createDevFS`/`_deleteDevFS` (runtime
  service layer, `pkg/dart_runtime_service`). Handle error 1001
  ("File system already exists") by delete-then-create; a failed run leaves
  the FS behind.
- DDS rejects a fresh client's first DevFS RPC with `Unknown method
  (-32601)` — issue one plain call (`getVM`) first. Always.
- Device delta delivery: HTTP-PUT (gzip body, `dev_fs_name` +
  `dev_fs_uri_b64` headers) to the VM-service HTTP endpoint, then
  `_reloadKernel(kernelFilePath: <device path from the createDevFS uri>)`.
  The public `reloadSources(rootLibUri:)` fallback was never needed.
- Web (DDK via `flutter run -d web-server`): recompile trigger = SIGUSR1 to
  the `--pid-file` pid (SIGUSR2 = restart); apply = dwds `reloadSources` on
  the debug-service ws (oka-driven; dwds wraps
  `dartDevEmbedder.hotReload`); the reload can settle after the RPC returns
  (`settleMs`); dwds's `evaluate` is broken in DDK mode — probes go through
  CDP `Runtime.evaluate` with synchronous DDK library handles
  (`dartDevEmbedder.importLibrary('package:…').member`); the honest
  no-restart probe is `performance.timeOrigin` (DDK reloads re-create
  function identities, so identity-hash holds are invalid on web). The
  isolate id persisting across apply is recorded in the apply wire facts.
- Baseline discipline: assert the pre-patch probe value explicitly after a
  controlled page reload — a stale page still running the previous patch
  makes the value probe vacuous.
- Device library URIs are `package:` form (`package:lastanswer/main.dart`);
  host JIT URIs are file paths — probe `library` fragments must match the
  target's convention.

## 12. Product-family lanes (2026-10-03, `gate_live_products.sh`)

Three real external products, one composition (`LivePatchSpec` →
`runLivePatch` → receipt). Per family, the lane that works:

- **Plain Dart CLI (oka itself)** — spawn under `--enable-vm-service`,
  **pre-stage the delta** (markers on → compile → restore → keep dill) and
  inject it as the session's compile fn; single-shot commands finish
  before a cold connect+compile path can. `_reloadKernel` on a
  paused-before-main isolate no-ops; `resume` before the pause event
  fails 105; drain piped stdout before asserting.
- **MCP stdio server (fmtk)** — drive JSONL on the child's stdin/out
  (filter non-JSON lines: the VM banner shares stdout). A kernel delta
  carries the ENTRY library's recompiled set only — two independent seams
  need two revisions over the same session (receipts prove pid hold).
- **Flutter desktop app (vosges)** — the delta MUST come from the app's
  own frontend, or the app's VM can't parse it:
  `<flutter>/bin/cache/dart-sdk/bin/dartaotruntime <flutter>/bin/cache/
  dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot --sdk-root
  <flutter>/bin/cache/artifacts/engine/common/flutter_patched_sdk
  --target=flutter --incremental --packages <app package_config.json>
  --output-dill <out> --output-incremental-dill <out> <entry>`, then
  DevFS push (same as devices) + `reloadSources {pause: false,
  rootLibUri}` (flutter's exact shape — `pause` present, no
  `packagesUri`). Foreign-fronted deltas fall into the kernel-isolate
  lane ("Error while starting Kernel isolate task" — desktop engines
  don't start one), and `_reloadKernel` on them RELEASE_ASSERTs and
  kills the app. DevFS `_createDevFS` on desktop returns a real local
  directory; `reloadSources` details carry `receivedLibraryCount` /
  `loadedLibraryCount` — check them.

Agent surface (ADR-0036 Tier 2, implemented): `oka_update/live_agent.dart`
declares `oka.live.patch` / `oka.live.watch` / `oka.live.verify` —
descriptors carry the `SurfaceActionDescriptor` shape (UAI 0.2.0);
`runLiveVerb(name, args, host)` dispatches into the session API and every
verb returns receipt JSON. Embeddings provide `LiveVerbHost` (compile +
root); no shell, no log scraping.
