# oka_dart_kernel

Kernel-graph experiments and gates for
[ADR-0032](../../docs/decisions/0032-oka-dart-kernel-graph-ownership.mdx).

The founding observations (evidence:
[deferred-patch-units spike](../../docs/evidence/deferred-patch-units-spike-2026-10-01.mdx),
§7–9):

- dart2js part files, DDC modules, and gen_snapshot loading units are all
  derived from deferred imports in the kernel dill — one graph, three chunk
  shapes. `oka_dart_kernel` owns that graph.
- The shipped `frontend_server` speaks an incremental protocol
  (`compile` / `recompile` / `accept`) that emits full and delta dills keyed
  by boundary keys; a delta dill is applied live by the VM service's private
  `_reloadKernel {kernelFilePath}`.
  The protocol refuses incremental AOT — JIT delta, web chunks, and AOT
  whole-revision are the three lanes, by the toolchain's own design.
- Multi-unit AOT loads and runs correctly on linux-x64 (Dart 3.13.2), but
  unit ELFs are code-only fragments coupled to their root and the VM refuses
  foreign unit files at load (`DeferredLoadException: ... different program
  than the main loading unit`). Native = whole-revision-at-restart.

## Layout

- `example/kernel_app/` — smallest self-contained app with one deferred unit;
  the input for the gates below.
- `tool/gen_kernel_dill.sh` — dill via the local SDK's `gen_kernel`.
- `tool/loading_units_probe.sh` — `gen_snapshot --loading_unit_manifest`
  probe (emits per-unit ELFs + JSON manifest).
- `tool/frontend_server_probe.sh` — hand-driven incremental session
  (compile → edit → recompile → delta dill).
- `tool/live_driver.dart`, `tool/linux_live_swap.sh` — the recorded Linux
  live-swap experiment (dockerized; runs against the spike workspace).
- `tool/gate1_roundtrip.sh` + `tool/kernel_roundtrip.dart` — **Gate 1**:
  dill → `pkg/kernel` round-trip → gen_snapshot → run.

## Toolchain inputs

Probes use the local `dart` SDK. Gate 1 additionally needs a pinned
dart-lang/sdk checkout for `pkg/kernel` (pub's `package:kernel` is abandoned;
SDK-internal sources are the only current form). `tool/gate1_roundtrip.sh`
respects `OKA_SDK_CHECKOUT` and otherwise shallow-clones the matching tag
into `~/xs/dart-sdks/sdk-<version>`. The checkout is a machine-local,
declared toolchain input (ADR-0013 posture) — never committed, never a fork.

## Status

- **G1 (kernel round-trip): substrate PASS** — see the pinned-checkout
  findings in `tool/kernel_roundtrip.dart`'s header. Post-TFA dill rewriting
  is not the supported seam (gen_snapshot rejects re-serialized dills);
  superseded by G1b.
- **G1b (pipeline seam): PASS** — `tool/gate_pipeline.dart` +
  `tool/gate_g1b_g2.sh`: a minimal runCompiler-shaped pipeline
  (`kernelForProgram` → transform hook → `runGlobalTransformations` →
  serialize) whose output gen_snapshot accepts and executes (macOS + Linux).
- **G2 (kernel deferred-ization): PASS** — `tool/gate_g2_linux.sh`: the hook
  flips `LibraryDependency.DeferredFlag` and inserts `await LoadLibrary(dep)`
  at the kernel level (zero source changes); a flat app then compiles into a
  dill gen_snapshot partitions into 2 loading units on Linux ELF (baseline: 1)
  and the partitioned app runs correctly, sdk#64162 stress included.
  Loading-unit splitting is ELF-only (`--loading_unit_manifest` triggers the
  deferred path; Mach-O refuses it) — macOS runs prove acceptance+execution.
- **G2.5 (multi-unit): PASS** — `tool/gate_g25_linux.sh`: two declared units
  → 3 loading units, each holding exactly its own library; app runs.
  Load-order policy: all-units-at-boot in declaration order.
- **G3 (live lane): PASS** — `tool/gate_g3.sh` + `tool/g3_live_reload.dart`:
  edit → oka `--delta` compiles the patched unit as the reload root →
  VM-service `_reloadKernel {kernelFilePath}` — the live process prints the
  new label without restart (984B delta, `loadedLibraryCount:1`). JIT lane
  only (the fs's incremental output is not a valid reload payload and
  deltas are refused under `--aot`; frontend full dills are unlinked and
  cannot run standalone).
- **G2.5-real / G3-real (real app): PASS** — the transform pointed at
  `~/xs/storage_problem/last_answer` (real Flutter workspace). Dependency-
  ordered partitioning over real packages
  (`tool/gate_g25_real_app.sh`, 3 ordered loading units, shared libs in
  root), the real Flutter `lib/main.dart` through the Flutter patched SDK to
  the engine's gen_snapshot manifest (`tool/gate_g25_real_flutter.sh`,
  4087 libs → 4 units), and the delta lane live-patching the running app
  (`tool/gate_g3_real_app.sh`). Partitioner core: `lib/src/unit_graph.dart`
  (kernel-free, unit-tested); kernel adapter: `tool/deferredize.dart`.
- **G3-B (per-unit reload under `flutter run`): PASS** —
  `tool/gate_g3_real_flutter.sh`: the stock frontend_server cannot scope
  deltas (recompile at ANY root re-serializes every transitive dependent:
  135MB), and public `reloadSources` has no kernel-bytes parameter — the
  flutter embedder's missing kernel isolate made that fallback fail with
  "Error while starting Kernel isolate task". The working lane compiles the
  patch unit's library as the reload root with `tool/gate_pipeline.dart
  --delta` (kernelForModule + prune: **11KB** delta) and applies it with
  the private VM-service `_reloadKernel {kernelFilePath}` over DDS →
  `ReloadReport success:true, loadedLibraryCount:1`, live `evaluate`
  returns the patched value, no restart. Findings in the evidence doc,
  §Per-unit reload under `flutter run`.
- **G4 (web lane): PASS** — `tool/gate_g4_web.sh`: two revisions through the
  pointer/manifest pipeline; conditional re-fetch transfers only changed
  artifacts (200/304/200), served bytes hash-match the manifest, served chunk
  carries the new revision marker.
- Run everything: `tool/gate.sh all` (per-gate: `gate.sh g1b|g2|g25|g3|g4`).
  Maintenance manual: `skills/oka-kernel` (repo root).
- Recorded evidence runs (spike workspace): `tool/recorded/`.

## Benchmarks & speed

`just bench-kernel` measures the composition loop on a hermetic app
(`tool/bench_live.dart`, schema `oka/kernel-benchmarks/v1`). The pipeline
has an AOT fast path — `dart compile exe tool/gate_pipeline.dart
-Dsdk_hash=<checkout>` (`tool/build_pipeline_exe.sh`); output is
byte-identical to the JIT run and the live driver picks it up via
`LIVE_PIPELINE_EXE`:

| step | JIT dart | AOT exe |
|---|---|---|
| whole-program compile | 5.3 s | **1.1 s** |
| per-unit delta | 3.7 s | **0.04 s** |
| full live apply (connect + patch + compile + apply + verify) | — | **0.57 s** |

Eligibility planning (`planRevisions`) costs ~12 us per run. Machine JSON
lands in `.steward/benchmark-summaries/`; numbers above measured on macOS
arm64 / dart 3.13.2 (2026-10-03) — compare only against similar setups.

## Showcase

`example/live_showcase/` — a two-file app, one `live_patch.json`, one
command: the running program's unit flips live (no restart) in ~30 s.
The cross-platform gate is `tool/gate_live_e2e.sh` (macOS VM, linux,
android, web — see `skills/oka-kernel/references/gates.md` LIVE-E2E).
