# oka_update

Authoring and planner surface for
[ADR-0031](../../docs/decisions/0031-declarative-patch-units.mdx) —
declarative patch units: unit specs, revision manifests, computed eligibility.

The kernel-graph machinery (partitioning, deferred-ization transforms,
frontend_server protocol) lives in
[oka_dart_kernel](../oka_dart_kernel) / [ADR-0032](../../docs/decisions/0032-oka-dart-kernel-graph-ownership.mdx).
The full API design (generator, pointer delivery, UpdateClient, verify
gating) is tracked in the design record referenced from ADR-0031's evidence.

## Status

- `UnitSpec` / `PatchUnit` — declared authoring surface (units are declared
  values, never code annotations).
- `planRevisions` — computed eligibility between two revision manifests:
  unit-body-only diffs are patchable; contract, structural, or core diffs
  produce an explicit alternative ("full release via store lane"). Verified
  against the spike (see evidence §"Generated declarative path"); contract
  fingerprints there are a regex prototype — production requires the analyzer.
- **`lib/src/live/` — the live session API** (2026-10-02, ADR-0034 P3
  progressed): a declarative `LivePatchSpec` (unit, find/replace patches,
  targets, probes) applied to running programs through composable
  `LivePatchTarget`s — `vm` (stock VM / DDS / flutter devices via DevFS
  push), `web` (dwds reloadSources + optional CDP page probes), `staged`
  (AOT next-launch, never implied live). `LivePatchSession` streams a
  `LivePatchEvent` per step and returns a `LivePatchReceipt`; the delta
  compiler is injected (oka's `gate_pipeline --delta` is the reference
  impl). Proven on last_answer across macOS VM, linux/amd64, android
  emulator, and Chrome — gate: `oka_dart_kernel/tool/gate_live_e2e.sh`,
  matrix in the evidence doc §"Live patching across platforms".

## Known limits (recorded, not hidden)

- Expression-bodied (`=>`) declarations are invisible to the prototype
  fingerprint — the analyzer is mandatory before this ships.
- A manifest's `coreFingerprint` must pin the compiled core: dart2js part
  filenames are stable across revisions while content changes, and a stale
  core rejects fresh chunks (mixed-revision hazard, evidence §9).

The path from this prototype to a production API — typed manifests,
analyzer-grade fingerprints, generator + `UpdateClient`, CI-grade gates —
is the gap analysis and ladder in
[ADR-0034](../../docs/decisions/0034-update-api-production-ladder.mdx)
(P0–P5). Nothing here is production-ready yet, by design of that record.
