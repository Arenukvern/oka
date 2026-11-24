# Changelog

## 0.13.0

### Minor Changes

- Raise Dart SDK floor to ^3.14.0 (Flutter 3.50 toolchain).
## 0.12.1

### Patch Changes

- **Release-train smoke cut — the first train where every published package
  has its own verified per-package pub.dev tag pattern
  (`<package>-v{{version}}`, repo `Arenukvern/oka`).**
  
  - Automated publishing verified server-side for all 17 published packages;
    `oka_service`, `oka_desktop`, `oka_google_play`, `oka_app_gallery`
    re-enabled after config drift, `oka_update` enabled for the first time.
  - No functional changes: the patch bumps exercise the OIDC publish legs
    end-to-end against the corrected tag patterns.
## 0.12.0

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.11.0

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.10.3

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.10.2

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.10.1

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.10.0

See `packages/oka/CHANGELOG.md` for train-wide release notes.

### Changed

- Joins the automated pub.dev OIDC publish train
  (`tool/release/train.dart list --publish`, first in dependency order). The
  last release on pub.dev was **0.8.1** (hand-published); 0.9.x train bumps were
  in-repo only until CI wiring landed.

### Added

- Vendored p1 contract, Perl leader, conformance suite, and probes from
  [universal_automation_ai_device_use @ `a86be1a2`](https://github.com/Arenukvern/universal_automation_ai_device_use/commit/a86be1a2)
  (`tool/VENDOR_NOTICE.md`).
- `posix-perl` backend: launch/stop via `owned_session_p1_leader.pl` (protocol,
  mode, marker, control channel, status lines, graceful executable hook).
- `tool/p1_matrix.sh` for local Linux/macOS matrix cells.

### Fixed

- Allow settle during stop; mirror UA term/grace/kill/settle order.
- Fail closed when control dir chmod 700 fails.
- Settle stop when kill command sent on control channel.

## 0.8.1

### Added

- Package skeleton (ADR-0052): identity tokens, owned-session launch spec/handle,
  `ProcessSessionBackend` with `posix-perl` and `posix-native` stubs, settlement
  and stop-receipt types, graceful cleanup hook, observation budget.
- Placeholder p1 contract doc and conformance harness directory for the dfp
  suite migration.


