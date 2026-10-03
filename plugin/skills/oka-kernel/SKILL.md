---
name: oka-kernel
description: >-
  Maintain and extend Oka's kernel-graph pipeline (oka_dart_kernel, ADR-0032):
  runCompiler-shaped pipeline with transform hooks, gen_snapshot loading
  units, kernel-level deferred-ization, the per-unit delta reload lane, and
  the gate harness (G1b, G2, G2.5, G3, G4 plus the real-app G2.5-real,
  G3-real, G3-B gates and the cross-platform LIVE-E2E live-patch session). Use when touching packages/oka_dart_kernel, working
  with pkg/kernel/pkg/vm from a pinned SDK checkout, debugging gen_snapshot,
  frontend_server, or VM-service reload behavior, or changing how Oka
  partitions Dart code into chunks/units.
license: MIT
metadata:
  version: 1.2.1
  author: Arenukvern
compatibility:
  - dart
  - flutter
---

# Oka kernel pipeline

Oka owns the Dart **kernel graph**: partition it per declared units, feed
stock backends (gen_snapshot, dart2js, DDC, frontend_server) their native
dills, and never fork or patch the SDK. Architecture and gate definitions:
`docs/decisions/0032-oka-dart-kernel-graph-ownership.mdx`. Evidence:
`docs/evidence/deferred-patch-units-spike-2026-10-01.mdx`. The concise
user/agent guide for live update itself (first steps, JIT dev loop vs AOT
production, dangers): `docs/guides/live_update.mdx`.

## Workflow

1. Read `packages/oka_dart_kernel/README.md` (gate status) and
   `references/gates.md` (what each gate proves, how to run it).
2. **Never** debug backend oddities before checking
   `references/troubleshooting.md` — most failures are a known toolchain
   trap with a recorded fix.
3. Provision the pinned SDK checkout: `tool/sdk_checkout.sh` (source it; sets
   `CHECKOUT`, `SDK`, `SDK_HASH`, `HOST_TARGET_OS`). Override location with
   `OKA_SDK_CHECKOUT`. The checkout is a machine-local toolchain input — never
   commit it, never edit its sources.
4. Run gates through `tool/gate.sh [g1b|g2|g25|g3|g4|all]` (toy suite) or the
   real-app scripts directly (`tool/gate_g25_real_*.sh`,
   `tool/gate_g3_real_*.sh`; they need `APP_ROOT` + flutter on the host).
   A gate passes only when its program prints the expected marker / its
   transfer pattern matches — partial output is not a pass.
5. New behavior goes through a gate **before** it lands in the ADR; update
   the ADR's gate list with the verdict, pass or fail.

## Hard rules

- Stock backends only: produce inputs for gen_snapshot/dart2js/DDC, never
  rewrite their outputs (post-TFA dill rewriting is proven unsupported —
  see `references/toolchain.md` §metadata).
- No SDK forks and no runtime patching; vendoring compiler *sources* from a
  pinned checkout is the allowed form of extension.
- Transforms run inside the pipeline (between CFE and TFA/serialization), at
  the hook in `tool/gate_pipeline.dart`.
- Application semantics stay honest: release lanes are reload/restart
  granularity; live swap exists only on the JIT dev lane via the private
  `_reloadKernel` RPC — never market it as release OTA.

## Deep material

- `references/toolchain.md` — the toolchain traps, metadata model, deferred
  representation, container workflows, frontend_server protocol, per-unit
  reload wire facts.
- `references/gates.md` — gate catalog, expected outputs, extension recipes.
- `references/troubleshooting.md` — symptom → cause → fix.
