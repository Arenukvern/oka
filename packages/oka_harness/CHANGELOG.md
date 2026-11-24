# Changelog

## 0.13.0

### Minor Changes

- Raise Dart SDK floor to ^3.14.0 (Flutter 3.50 toolchain).
- Updated `oka_android` dependency constraint to `^0.14.0`.
- Updated `resource_composition` dependency constraint to `^0.13.0`.
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

### Patch Changes

- Updated `oka_android` dependency constraint to `^0.14.0`.
All notable changes to this package are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

## 0.8.1

- Part of the 0.8.1 train: usage-banner and doctor doc-pointer fixes in the
  `oka` CLI; no package-specific changes in this package.

## 0.8.0

- Widen `universal_automation_interface` to ^0.3.0 and resolve `flutter_mcp_toolkit_core` 7.0.1 (coordinate actions).

## 0.7.0

- Release train alignment with `oka` 0.7.0.

## 0.4.0

### Added

- `AndroidAppTarget` (ADR-0026): an `AppTarget` over the owning `oka dev`
  session — builds/installs/launches through oka, reads the forwarded VM
  service URI from `.flutter_mcp/runner-session.json` (mcp_flutter ADR-0014
  spec v2), streams `adb logcat` into the harness `LogTap`, and tears the
  owning session down on `stop()`. Refuses `launch(build: false)` — no
  second owner.
- `driverForLiveSession(projectDir)`: attach a `WidgetDriver` to an
  already-running session without launching anything.
- Offline test suite: fake `oka` script covering launch → attach → stop,
  arg threading, and the no-session timeout/teardown path.



