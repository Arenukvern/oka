# oka_artifacts

Content-addressed artifact store with delta chains
([ADR-0043](../docs/decisions/0043-artifact-store-delta-chains.mdx)):
**git stores pointers, bytes live here**, and the snapshot cadence
emerges from measured delta ratios — the "diff → diff… → snapshot"
storage shape, with no configuration and no cron.

## 60-second version

```dart
final store = ArtifactStore.forMachine(); // ~/.oka/artifacts
final receipt = store.record(
  File('build/app.dill').readAsBytesSync(),
  name: 'app-dill',
  policy: const DeltaChain(), // rollover at 35% delta ratio, depth 8, every 20
  codec: const ZstdCliCodec(),
);
print(receipt); // app-dill delta    1a2b3c4d5e6f (delta 8211 / full 33554432)

final full = store.materialize(name: 'app-dill', codec: const ZstdCliCodec());
// full.sha256 — identity is the digest; every chain step was hash-verified.
```

Laws: identical content is a no-op write; every materialization step is
hash-verified; an unavailable codec degrades to snapshots **loudly**
(the receipt names it); the store lives outside the visible codebase —
a developer's tree gains nothing. Sharing a warm start across clones is
opt-in: write an `ArtifactPointer` (~200 bytes, provenance required)
where the binary used to be, and host `blobs/<sha>` on any static HTTP
backend — the digest is the integrity check.

## Where to look

- ADR-0043 for the why (and the scoped note vs the 2026-09-28
  build-cache decision).
- CLI: `dart run bin/oka_artifacts.dart put|materialize|verify|status`.
- The first wired consumer: the harness `harnessd.jit.dill` rebuild lane.
