# Changelog

## 0.9.0 <!-- x-release-please-version -->

See `packages/oka/CHANGELOG.md` for train-wide release notes.

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
