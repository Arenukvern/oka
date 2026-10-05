# Troubleshooting — symptom → cause → fix

## gen_snapshot

| Symptom | Cause | Fix |
|---|---|---|
| `Missing table selector metadata!` on a *rewritten* dill | post-TFA re-serialization unsupported (C++ reader needs original context) | move the transform inside the pipeline (`gate_pipeline.dart` hook); do not rewrite lowered dills |
| Same message on a *fresh* pipeline dill | metadata repositories not registered, or `sdk_hash` placeholder | register all twelve repos (only relevant when re-serializing); run with `-Dsdk_hash=<release short hash>` |
| `deferred loading not implemented for Mach-O` | `--loading_unit_manifest` (multi-unit) is ELF-only | drop the manifest flag on macOS (accept+run proof); do the split proof on Linux (`tool/gate_g2_linux.sh`) |
| `DeferredLoadException: ... different program than the main loading unit` | unit file replaced under a running program — VM program-identity check | expected behavior: whole-revision swaps only; never mix units across builds |

## frontend_server / live reload

| Symptom | Cause | Fix |
|---|---|---|
| `--incremental option cannot be used with --aot` | protocol lane boundary | drop `--aot`; deltas are JIT-lane only |
| Running the emitted full dill fails (`Undefined name 'stdout'` / recompiles from source) | frontend_server full dills are unlinked (app-only) | run the app from source with `--enable-vm-service`; use frontend_server only for delta generation |
| `Stream has already been listened to` on the second RPC | websocket is single-subscription | one persistent listener dispatching by id (see `tool/g3_live_reload.dart`) |
| `getVM` result lacks `isolateIds` | protocol version differences | fall back to `result['isolates'][i]['id']` |
| reloadSources succeeds but behavior unchanged | delta dill empty or wrong invalidated set | verify the delta dill byte size > 0 and the invalidated URI list contains the edited file |

## Pipeline compile

| Symptom | Cause | Fix |
|---|---|---|
| `dart%3Acore` / `untranslatable-uri` errors compiling dart:core from source | `sdkRoot` set together with `sdkSummary` | set `sdkSummary` only |
| `Null check operator` on `getTarget(...)` | vm target not registered | call `installAdditionalTargets()` first |
| `The URI '...' has no scheme` internal problem | relative entry path | absolutize: `Uri.file(File(p).absolute.path)` |
| `_findPackages` crash under containers | walk-up discovery unreliable across mounts | pass `packagesFileUri` explicitly (`DART_PACKAGES_CONFIG`) |
| pub-cache deps clash (`SourceLocation isn't a type` in yaml etc.) | per-package newest-in-cache resolution | pub-solve a shim package and merge entries (gate scripts step 2) |
| `'LibraryDependency' isn't a type` under workspace analyze | kernel/vm/front_end resolve only under the gate's generated config | keep such tools in `analysis_options.yaml` exclude |

## Containers

| Symptom | Cause | Fix |
|---|---|---|
| `bash -s` container exits 0 instantly, no output | `docker run` without `-i` gives the heredoc stdin EOF | add `-i` |
| `pub get failed` inside container | no network/pub cache in image | generate package_configs; avoid third-party imports in gate subjects |
| `strings: command not found` | binutils absent | `grep -a` on the binary |
| dartaotruntime `invalid ELF header` on a `.dart` file | dartaotruntime runs AOT snapshots only | use JIT `dart` for helper scripts |

## Real-app gates

| Symptom | Cause | Fix |
|---|---|---|
| `Cannot remove from a fixed-length list` at main teardown, AOT run | `await` inserted into a sync `main` (or post-CFE asyncMarker flip) | make main async (`Future<void> main() async`); the transform refuses sync mains |
| Bus error (pc=0x1) at first cross-unit call, flags-only build | AOT part loads are lazy — no guards inserted | keep the guards (synthetic imports alone don't load parts) |
| Units land back in root in the manifest | `dart:mixin_deduplication` re-linked them non-deferred mid-pipeline | run `runGlobalTransformationsWithUnits` (re-flag hook before `deferred_loading`) |
| Pattern matches nothing / members empty on a real app | circular imports (screens ↔ router) put every seed-entering edge inside the closure | fixed in `unit_graph.dart` (defer every non-seed→seed entering edge); update the checkout-mapped sources |
| `Null check operator` in `DillLoader.read` / "No library found for dart:cli" | stock VM target vs Flutter patched SDK | `OKA_TARGET=flutter` (and `DART_SDK_SUMMARY=<patched_sdk>/platform_strong.dill`) |
| `The language version is not specified correctly in the packages file` | pipeline package_config `languageVersion: 3.13.4` | use major.minor (`3.13`) |
| gen_snapshot rejects the dill on a flutter-app compile | `-Dsdk_hash` mismatch with the engine's dart version | checkout `sdk-<flutter dart version>`, hash = `git rev-parse --short=10 HEAD` |
| frontend_server `RangeError` in `ForInLowering.transformForInStatement` | 3.13.2 fs bug on some app code | use flutter's fs (`G3_FS_SDK_ROOT=<flutter>/.../flutter_patched_sdk`, `G3_FS_TARGET=flutter`) |
| `reloadSources: invalid 'isolateId' parameter: (null)` with params sent | 3.13.4 VM service drops params-bearing requests | run the app under the 3.13.2 VM, or go through DDS (flutter run) |
| `Error while starting Kernel isolate task` on reload | no kernel isolate in the embedder: `reloadSources` without a root-lib binary falls back to source recompile via `KernelIsolate::Start()`, which the flutter embedder never starts | apply a kernel delta with the private `_reloadKernel {isolateId, kernelFilePath}` instead (stock `dart` VMs can also reload from patched sources on disk) |
| delta is ~full dill size (135 MB on last_answer), any recompile root | the stock frontend_server re-serializes every transitive dependent — re-rooting at the unit library does NOT scope it | compile the delta outside the incremental session: `gate_pipeline.dart --delta <unit.dart> <out.dill>` (kernelForModule + prune, 11KB) |
| `reloadSources(kernelBytes: …)` returns success but the patch isn't in the effect | there is no `kernelBytes` param — unknown params are dropped silently; the reload recompiled from source | use `_reloadKernel {kernelFilePath}`; check `ReloadReport.details.receivedLibraryCount` |
| `_reloadKernel` crashes the VM: `RELEASE_ASSERT(delta_program != nullptr)` | the payload is a frontend_server incremental-serializer dill — the VM's `DeltaProgram` reader refuses that layout | compile the delta with `gate_pipeline.dart --delta` (plain writeComponentFile parses); never feed fs recompile output to `_reloadKernel` |
| `_reloadKernel` right after app start: `invalid 'isolateId' parameter: (null)` | the main isolate is not yet runnable (service port opens before main runs) | retry with backoff until the isolate is up (see `tool/g3_live_reload.dart`) |

| `app-aot-macho` → `Unrecognized value for snapshot_kind` | the kind name changed in 3.13 | use `app-aot-macho-dylib` (or `app-aot-pecoff-obj` for windows PE) |
| macho kind + manifest → `deferred loading not implemented for Mach-O` | Mach-O unit packaging is genuinely unimplemented | use `app-aot-elf` — it splits AND runs on macOS (VM's own ELF loader) |
| cross gen_snapshot (flutter engine) → bare `ApiError` on the dill | dill built from a different SDK version than the gen_snapshot | rebuild the dill from the matching checkout with the matching `-Dsdk_hash` |

| android runtime: `Snapshot not compatible ... no-compressed-pointers` | the runtime was built without compressed pointers; flutter arm64 snapshots use them | gn-gen with `dart_use_compressed_pointers=true` (see toolchain §10) |

| DevFS RPC → `Unknown method "createDevFS" (-32601)` | Dart 3.13 renamed the RPC to `_createDevFS` (runtime service layer) AND DDS drops a fresh client's first DevFS RPC | call `_createDevFS`; send one `getVM` first (see `oka_update/lib/src/live/vm_service_wire.dart`) |
| `_createDevFS` → `File system already exists (1001)` | a previous failed run left the DevFS behind | delete (`_deleteDevFS`) then recreate — mirror flutter_tools; `devfsCreate` is idempotent |
| device `_reloadKernel` fails with a host path | the device VM cannot open host paths | push via DevFS HTTP PUT (gzip, `dev_fs_name` + `dev_fs_uri_b64`), then apply with the DEVICE path from the createDevFS uri |
| dwds DDK `evaluate` → NoSuchMethodError / `type 'Null' is not a subtype of 'String'` | dwds's `WebSocketProxyService.evaluate` dispatcher is broken for our call shapes | probe through CDP `Runtime.evaluate` with `dartDevEmbedder.importLibrary('package:…').member` (synchronous DDK handles) |
| web probe reads the OLD value after a successful reload | the page-level reload settles after `reloadSources` returns; DDK reloads also re-create function identities | declarative `settleMs` before verify; use `performance.timeOrigin` (not identity hashes) as the no-restart hold on web |
| web value probe vacuous (before == after) | the page still runs a previously patched module (stale baseline) | restore source → SIGUSR1 recompile → `location.reload()` → assert baseline `b` BEFORE patching (the gate does this) |

| `_reloadKernel` reports success but the value never changes | the delta's library importUri does not match how the app loaded it (package: vs file:) — the VM adds a stray copy instead of replacing | keep the URI story coherent: run the app under the SAME package config the delta was compiled with (`--packages=...`, not an env var — `DART_PACKAGES_CONFIG` is not a VM flag) |
| patched `const` field keeps its old value after a clean reload | const canonical values survive kernel reloads; only freshly-executed code changes | patch function bodies (or constructor defaults — they run at construction), and read values through calls, not field reads |

| flutter desktop `_reloadKernel` → `RELEASE_ASSERT(delta_program != nullptr)` and the app DIES | the delta isn't parseable by the app's VM (foreign frontend) — `_reloadKernel` asserts instead of refusing; never trial-and-error this RPC on flutter-hosted desktop VMs | compile with the app's own frontend (below) and apply via `reloadSources {pause: false, rootLibUri}` |
| flutter desktop `reloadSources(rootLibUri)` → `success:false, "Error while starting Kernel isolate task"` | the delta failed `ReadFromTypedData` (frontend/version mismatch), so the VM fell into the kernel-isolate lane — and desktop engines don't start one (`start_kernel_isolate` unset) | compile the delta with the app's own frontend: `<flutter>/bin/cache/dart-sdk/bin/dartaotruntime <flutter>/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot --sdk-root <flutter>/bin/cache/artifacts/engine/common/flutter_patched_sdk --target=flutter --incremental --packages <app package_config.json> --output-dill <out> --output-incremental-dill <out> <entry>` (see `tool/live_products_flutter_app.dart`) |
| `reloadSources` "succeeds" but no library loads | report says success yet `loadedLibraryCount` is 0/absent — the rootLibUri wasn't consumed as kernel | check `ReloadReport.details.receivedLibraryCount/loadedLibraryCount` in the response; a parse-fallback produces the kernel-isolate error above instead |
| a plain Dart CLI exits before the patch can apply | single-shot commands outlive nothing; connect+baseline+compile takes ~2.5s | pre-stage the delta (markers on → compile → restore → keep dill) and inject it as the session's compile fn (`tool/live_products_oka_cli.dart`); `_reloadKernel` on a paused-before-main isolate no-ops, and `resume` before the pause event fails 105 |
| child CLI output incomplete when asserting after `exitCode` | piped stdout is block-buffered in the child | await stdout/stderr subscription completion (or drain) before reading the captured log |
| driver hangs forever on the first probe RPC | the ws upgrade can hang in the VM service's startup window; a booting service may answer `getIsolate` after multi-second stalls | bound each probe RPC (~2s) and retry (the wire's `findLibrary` does both); keep the target alive (or own its restart) |
| patching a build tool mid-build invalidates the tool's own caches | build digests that include the tool's sources make the build self-referential (oka example: patching the CLI re-entered artifact staging; aapt2 failed on lost icon res) | host live-patch demos on non-build commands; record the digest scoping as a product bug (oka follow-up: step digests exclude the driving tool) |
| gate worktree `flutter pub get` resolves DIFFERENT versions than the app checkout | the app may not commit `pubspec.lock` (last_answer doesn't); a fresh resolve picks newer majors whose APIs differ (file_picker 12 stable split web into a list-returning platform interface) | copy the checkout's `pubspec.lock` into the worktree before pub get — resolution state is environment, not app code; never "fix" app source for a resolution only the worktree sees |
| dev-session `flutter run -d web-server` never announces the VM service | dwds prints "A Dart VM Service on Chrome…" only after a PAGE CONNECTS | launch Chrome between "is being served at" and the service line (the `_launchWeb` ordering in `tool/oka_run_dev.dart`, mirroring `live_e2e_web.dart`) |
| desktop DDS `evaluate` of a String returns `c` UNQUOTED, plain-VM returns `"c"` | DDS unwraps the JSON value; the raw VM service JSON-encodes | don't share one `expect` across desktop-VM and DDS targets; prefer substring expects (`c`) over JSON-quoted ones |
| `callServiceExtension` JSON-RPC → `Unknown method "callServiceExtension"` (-32601) on raw AND DDS | that method does not exist on the wire; package:vm_service sends the EXTENSION NAME as the JSON-RPC method with `{isolateId, ...args}` params (`ext.*` dispatches directly) | call `ext.flutter.reassemble` / `ext.flutter.evict` as the METHOD (see `VmServiceWire`); `getIsolate.extensionRPCs` over HTTP lists what is registered |
| an app registers ZERO `ext.flutter.*` extensions (only `ext.dart.io.*` / `ext.ui.window.*`) | a non-standard binding bootstrap suppresses framework registration — mcp_toolkit's `bootstrapFlutter` measured: 11 extensions vs 74 under `WidgetsFlutterBinding.ensureInitialized` | bootstrap with the standard binding; report the toolkit binding upstream |
| desktop asset hot reload stays stale even after writing the bundle's flutter_assets + `ext.flutter.evict` | the debug macOS engine caches asset mappings: it reads the BUILD PRODUCT's `App.framework/Versions/A/Resources/flutter_assets` (never flutter_tools' DevFS dir) and keeps the first mapping per key until the next engine cycle | sync bytes there + evict (the honest lane, `gate_dev_assets.sh`); the next `R` serves the new bytes; live freshness = engine-seam research line (flutter has the same ceiling) |
| VM `evaluate` returns a `_Future` instance instead of the value | the evaluator does NOT await | expose a two-phase helper in the app: async refresh writes a cached value, sync getter returns it (`refreshHelloAsset()` → `helloAssetFingerprint()` in the example app) |
| shader changes don't need `R` (unlike other assets) — why | shaders evict ENGINE-side: flutter_tools/oka sync the compiled `.iplr` under the SOURCE's key (`FragmentProgram.fromAsset` takes the `.frag` path) and call `ext.ui.window.reinitializeShader {assetKey}`, which the engine handles natively | dev-session shader lane: `compileShader` (impellerc `--iplr --sl=… --spirv=… --sksl --runtime-stage-metal`, `bin/cache/artifacts/engine/<host>/impellerc` + `shader_lib` include) then sync + `reinitializeShader` (`gate_dev_assets.sh`); 3D models are ordinary assets (flutter_scene runtime `.glb` or offline-imported bundles) — next-load-fresh |
| dev-session bring-up "hangs" for minutes with no output | two measured causes, neither the delta lane: (1) `flutter run`'s implicit pub resolve on a big workspace takes ~4 min of real tooling time (offline included); (2) a killed session leaves a flutter/dart process holding the Swift Package Manager lock — everything then queues behind "Waiting for another flutter command…" | the session now runs `pub get --offline` ONCE with the lock-wait surfaced live and a 3-min named timeout, then launches `flutter run --no-pub`; kill zombie flutter/dart processes before retrying (gate logs show the pub line) |
