# 06 — Live patch: update apps without a store

The research frontier: apply changes to a **running** Dart/Flutter app.
Two modes, one composition (`LivePatchSpec`):

- **Dev loop** — JIT hot patching that preserves app state (beyond hot
  reload: endless patching, AOT revision slots).
- **Air channel** — ship patches to installed apps directly
  ([ADR-0037](../../docs/decisions/0037-air-channel-invisible-patches.mdx)):
  no store review, no full redeploy.

> **Status: research preview.** The stack (`oka_dart_kernel` + `oka_update`)
> is proven by gates across macOS/linux/android/web and three real products,
> but is not yet on pub.dev — it runs from an oka repo checkout.

## 30-second demo

From the repo root:

```bash
packages/oka_dart_kernel/example/live_showcase/run.sh
# a running app gets patched live — the whole patch is one Dart value
```

## The air channel in five lines of concept

1. **Declare units once** — which libraries form a patchable unit:

   ```dart
   // tool/patch_units.dart
   const patchUnits = UnitsSpec(revision: 'baseline', units: [
     PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),
   ]);
   ```

2. **Edit the unit in your working tree** — normal Dart, no patch code.
3. **Ship** — everything else is derived (revision, manifests, deltas):

   ```bash
   oka ship                 # derive + build channel (default build/oka-channel/)
   oka ship --dry-run       # plan + receipt, publish nothing
   oka ship --publish-git ~/path/to/origin-repo   # push to branch oka-channel
   ```

4. **Client resolves** — `UpdateClient` + `planChain` (file dir, HTTP, or
   git branch) pick the delta vs the installed snapshot.
5. **Engine applies** — the patch lands in the running app; receipts carry
   the reload report.

A complete working sample lives in the main repo:
[`example/lib/units/`](../../example/lib/units) +
[`example/tool/patch_units.dart`](../../example/tool/patch_units.dart), and
the end-to-end gates are
[`gate_air_channel.sh`](../../packages/oka_dart_kernel/tool/gate_air_channel.sh)
(engine: ship → git branch → VM apply) and
[`gate_air_web.sh`](../../packages/oka_dart_kernel/tool/gate_air_web.sh)
(web: ship → release build → static host → HTTP client). The dev loop
runs as one command — `oka run dev --platform macos|web`
([guide](../../docs/guides/live_update.mdx)).

## Learn more

- [Live update guide](../../docs/guides/live_update.mdx) — first steps →
  JIT dev loop → AOT production, with an honest dangers list.
- ADRs [0031](../../docs/decisions/0031-declarative-patch-units.mdx)–
  [0037](../../docs/decisions/0037-air-channel-invisible-patches.mdx) —
  the design records.
