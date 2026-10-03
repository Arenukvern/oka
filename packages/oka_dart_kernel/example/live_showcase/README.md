# Live-patch showcase

A two-file app, one declarative patch spec, one command — watch a running
program swap a unit's code live (no restart) in about 30 seconds.

## What you will see

```
== [2/4] start the app with a VM service (ws://127.0.0.1:8242/ws)
app: feature=alpha-v1 boot=1791002…
== [3/4] apply the declarative live patch (oka_update LivePatchSession)
live: eligibility: patchable
live: [showcase-vm] connected; 2 baseline probe(s) captured
live: wrote 1 patch file(s) on disk
live: unit delta 968 bytes at …/feature.delta.dill
live: [showcase-vm] applying delta via wire
live: [showcase-vm] applied in 12 ms (reloadKernel)
live: [showcase-vm] probe `status()`: …alpha-v1… -> …alpha-v2-live…
live: [showcase-vm] probe `bootStamp`: 1791002… -> 1791002… (held — no restart)
live patch OK — unit `feature` rev showcase-v2
```

The `bootStamp` probe is the no-restart proof: the process was never
restarted, yet `feature()` — a real member of the declared `feature` unit —
returns the patched value.

## Run it

```bash
./run.sh
```

Requires a pinned dart SDK checkout of the running dart's version
(auto-discovered at `~/xs/dart-sdks/sdk-<version>`; override with
`OKA_SDK_CHECKOUT`). See `skills/oka-kernel/references/toolchain.md` for
how to provision one.

## The pieces

| File | Role |
|---|---|
| `app/lib/units/feature.dart` | the declared patch unit (patch the function body) |
| `app/lib/main.dart` | the app: prints status, stays alive for the patch |
| `patch.dart` | **the whole patch as one Dart value** — unit, edit, target wire, probes |
| `run.sh` | starts the app, then runs `dart patch.dart` |

There is no config file: oka declares and controls everything in Dart
(ADR-0035). `patch.dart` composes `LivePatchSpec` (oka_update) and calls
`runLivePatch` with `resolvePipelineToolchain()` +
`pipelineDeltaCompiler()` (oka_dart_kernel — pinned checkout, AOT delta
pipeline, cached under ~/.oka). JSON/YAML exist only as machine OUTPUT
(receipts, manifests), never as authored input.

One rule the showcase encodes (ADR-0035 §2, URI coherence): run the app
under the SAME package config the delta is compiled with
(`TargetSpec.vmPort` + `appPackagesConfig`), and patch function bodies —
a `const` field's canonical value survives a kernel reload.

The cross-platform version of this exact flow — mac VM, linux, android,
web — is `tool/gate_live_e2e.sh`.
