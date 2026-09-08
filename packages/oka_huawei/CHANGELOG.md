# Changelog — oka_huawei

All notable changes to this package are documented here. The release train
is repo-wide: versions move with the root `VERSION` (see
`tool/release/check_version_sync.sh`).

## 0.1.6

- Initial release (ADR-0014 P2): `HuaweiPublishTarget` (dry-run publish plan
  + AppGallery Connect REST upload tail), `AgcClient` over an injectable
  HTTP transport, `HuaweiReleaseConfig` typed release metadata, and
  `HuaweiBuildVariant` — the GMS-excluding AndroidBuild variant whose
  composition is validated by the standard artifact checker before any tool
  runs.
