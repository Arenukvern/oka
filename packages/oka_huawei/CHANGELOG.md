# Changelog — oka_huawei

All notable changes to this package are documented here. The release train
is repo-wide: versions move with the root `VERSION` (see
`tool/release/check_version_sync.sh`).

<!-- oka-train-changelog: packages/oka/CHANGELOG.md -->

## 0.9.0

- Version aligned with the oka 0.9.0 train; see `packages/oka/CHANGELOG.md`.

## 0.8.1

- Part of the 0.8.1 train: usage-banner and doctor doc-pointer fixes in the
  `oka` CLI; no package-specific changes in this package.

## 0.8.0

- Part of the 0.8.0 train: Dart SDK floors ^3.13.0 (extraneous `final` parameter modifiers dropped); no package-specific changes.

## 0.7.0

- Release train alignment with `oka` 0.7.0.

## 0.4.0

- Version alignment with the 0.4.0 oka release train; no functional changes in this package.

## 0.2.0

- Join the complete package release train with compatible `0.2.0` internal
  dependency constraints.

## 0.1.6

- Initial release (ADR-0014 P2): `HuaweiPublishTarget` (dry-run publish plan
  + AppGallery Connect REST upload tail), `AgcClient` over an injectable
  HTTP transport, `HuaweiReleaseConfig` typed release metadata, and
  `HuaweiBuildVariant` — the GMS-excluding AndroidBuild variant whose
  composition is validated by the standard artifact checker before any tool
  runs.
