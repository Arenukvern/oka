# Changelog

All notable changes to this package are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
