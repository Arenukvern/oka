# oka_devices

Immutable **declarative device and dev-run specs** for the oka ecosystem
(R2 value-object API — types and validation only; provisioning lands in later
revisions).

Specs are fail-closed values: call `validate()` to collect every violation, or
`ensureValid()` to throw a single `SpecViolationException` listing them all.

## Surface

- `Display`, `PortChoice`, `PortPlan`
- `DeviceSpec` → `EmulatorSpec`, `PhysicalDeviceSpec`
- `AppSpec`, `RunSpec`
- Pure helpers: `EmulatorSpec.emulatorArgv()`, `RunSpec.plan()` (flutter attach
  argv)

## Status

R2 — **no behavior change** in the main oka CLI or `oka dev android` path.
