# Changelog

## 0.9.0 <!-- x-release-please-version -->

See `packages/oka/CHANGELOG.md` for train-wide release notes.

- Dependency lockfile hygiene (`fix: locks`).

## 0.8.1

- Part of the 0.8.1 train: usage-banner and doctor doc-pointer fixes in the
  `oka` CLI; no package-specific changes in this package.

## 0.8.0

- Part of the 0.8.0 train: Dart SDK floors ^3.13.0 (extraneous `final` parameter modifiers dropped); no package-specific changes.

## 0.7.0

### Added

- `oka artifacts` CLI surface in the `oka` package (`put`, `materialize`,
  `verify`).

## 0.6.0

- Initial release: `ArtifactStore` (content-addressed snapshots,
  per-artifact delta chains with ratio-triggered rollover, hash-verified
  materialization, atomic writes), `DeltaCodec` seam with
  `ZstdCliCodec` (`zstd --patch-from`), closed storage strategies
  (`SnapshotOnly`, `DeltaChain`), and `ArtifactPointer` provenance
  manifests for git (ADR-0043).
