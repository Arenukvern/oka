# Gate catalog (ADR-0032)

Run any subset: `tool/gate.sh [g1b|g2|g25|g3|g4|all]`. Requirements: local
dart 3.13.2+ (SDK bumps need re-verification — see
`references/toolchain.md` §1/§5), docker for the Linux split proofs, and the
pinned checkout (`tool/sdk_checkout.sh`).

| Gate | Proves | Script | Status (2026-10-02) |
|---|---|---|---|
| G1 | pkg/kernel+pkg/vm usable as libraries; lossless metadata round-trip | `tool/kernel_roundtrip.dart` (+ `tool/gate1_roundtrip.sh`) | substrate PASS; post-TFA rewrite rejected by gen_snapshot → superseded by G1b |
| G1b | pipeline seam: CFE → hook → VM transforms → dill, gen_snapshot accepts + runs | `tool/gate_g1b_g2.sh` | PASS (macOS macho + Linux ELF) |
| G2 | kernel-level deferred-ization: flat app → deferred units, no source changes | `tool/gate_g2_linux.sh` | PASS (2 loading units on ELF, app runs, #64162 stress passes) |
| G2.5 | multi-unit partitioning: 2 units → 3 loading units, per-unit isolation | `tool/gate_g25_linux.sh` | PASS (root/tiny/greet in units 1/2/3) |
| G3 | live lane: edit → unit delta (`--delta`) → `_reloadKernel` → live process swaps code | `tool/gate_g3.sh` | PASS (tiny-v1 → tiny-v3-live via 984B delta, no restart) |
| G4 | web lane: pointer/manifest pipeline transfers only changed chunks, verify rung green | `tool/gate_g4_web.sh` | PASS (200/304/200 pattern, hash match, rev marker) |
| G2.5-real | the transform on a REAL app: real packages with a dependency chain → ordered loading units, shared libs in root, AOT runs | `tool/gate_g25_real_app.sh` (Linux container, APP_ROOT=~/xs/storage_problem/last_answer) | PASS (root/2/3, doc_replica before doc_replica_store) |
| G2.5-real-B | the REAL Flutter `lib/main.dart` through the patched SDK → engine gen_snapshot manifest | `tool/gate_g25_real_flutter.sh` (host; needs a dart-sdks checkout of the flutter dart version) | PASS (4087 libs → 4 units; single-seam feature coherent, multi-seam fragments per seam) |
| G3-real | delta lane live-patches the real app: real module edit → unit delta → `_reloadKernel(kernelFilePath)` → live process prints patched value | `tool/gate_g3_real_app.sh` (delta checkout = the app VM's dart version) | PASS (ReloadReport success, no restart) |
| G3-B | per-unit delta through `flutter run` + DDS: unit library compiled as reload root, `_reloadKernel`, `evaluate` on the real library | `tool/gate_g3_real_flutter.sh` (G3B_DELTA_MODE=unit; `fs` mode reproduces the stock-fs negative) | PASS (11KB delta vs 135MB stock, `receivedLibraryCount:2`/`loadedLibraryCount:1`, evaluate returns patched value, no restart) |
| LIVE-E2E | the live session API across platforms: one declarative spec, four targets — mac VM, linux/amd64 docker, flutter android (DevFS + `_reloadKernel`), DDK web (oka-driven dwds reload + CDP probes) — each proving value-flip + no-restart | `tool/gate_live_e2e.sh` (APP_ROOT=~/xs/storage_problem/last_answer) | PASS (all four legs; matrix in evidence §Live patching across platforms) |
| ENDLESS | the endless dev loop on a real engine: boot with state, patch continue ×2, patch RESET ×2, boot-state probe holds, 0 restarts | `tool/gate_endless_loop.sh` (LIVE_APP_ROOT=~/xs/storage_problem/last_answer) | PASS (loop-1..4, state held after every step) |
| AOT-SLOTS | S2 physical proof: AOT program with loading-unit manifest boots r1, flips to r2 IN-PROCESS (same pid, no VM service) | `tool/gate_aot_slots.sh` | PASS (aot-v1 → aot-v2-live, pid unchanged) |
| PRODUCTS | the composition API on three real external products: oka CLI itself (pre-staged delta mid-run), mcp_flutter's fmtk MCP server (two revisions over ONE stdio session, visible MCP response flip), vosges Flutter desktop (app-frontend delta mid-boot) — probe flip + continuity hold per leg | `tool/gate_live_products.sh` (env: MCP_FLUTTER_ROOT, VOSGES_APP_ROOT, FLUTTER_BIN) | PASS (oka-cli / mcp-stdio / flutter-app; wire facts in evidence §Product families) |
| AOT-PLATFORMS | native per-unit matrix: `app-aot-elf` split+run on mac/linux amd64+arm64; android RUN on emulator (stock checkout runtime, optional leg via `ANDROID_DARTAOTRUNTIME`); ios artifacts; macho refusal verbatim | `tool/gate_aot_platforms.sh` (needs flutter + docker; android leg needs adb + a built runtime) | PASS (macOS + android RUNs are the new results — part files load via the VM's own ELF loader / `Loader::DeferredLoadHandler`; ios runtime = embedder seam) |

## Extension recipes

### New transform (like deferred-ization)

1. Add it behind a flag in `tool/gate_pipeline.dart`'s `transformHook`.
2. Keep it before `runGlobalTransformations` — transformations and backends
   see the final graph; metadata covers your nodes.
3. Extend the relevant gate: new example unit under
   `example/kernel_app/lib/units/`, `--unit=` flag, unit-map assertion in the
   linux gate (`tool/manifest_units.dart` output).
4. Record the verdict in the ADR-0032 gate list, pass or fail.

### Gate after an SDK upgrade

1. `tool/sdk_checkout.sh` clones the new tag automatically (or set
   `OKA_SDK_CHECKOUT`).
2. Update the baked `sdk_hash` in the gate scripts if `git rev-parse
   --short=10 HEAD` changed.
3. `tool/gate.sh all`; on metadata-shape failures re-check the repository
   list in `references/toolchain.md` §1 (new SDK versions can add
   subsections).
4. Watch `docs/decisions/0032` consequences: pkg/kernel APIs churn
   (`loadComponentFromBytes` vs `BinaryBuilderWithMetadata` moved before).
