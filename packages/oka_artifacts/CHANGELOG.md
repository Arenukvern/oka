# Changelog

## 0.6.0

- Initial release: `ArtifactStore` (content-addressed snapshots,
  per-artifact delta chains with ratio-triggered rollover, hash-verified
  materialization, atomic writes), `DeltaCodec` seam with
  `ZstdCliCodec` (`zstd --patch-from`), closed storage strategies
  (`SnapshotOnly`, `DeltaChain`), and `ArtifactPointer` provenance
  manifests for git (ADR-0043).
