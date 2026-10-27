# Changelog

## 0.9.1 <!-- x-release-please-version -->

See `packages/oka/CHANGELOG.md` for train-wide release notes.

## 0.8.1

- Part of the 0.8.1 train: usage-banner and doctor doc-pointer fixes in the
  `oka` CLI; no package-specific changes in this package.

## 0.8.0

- Codemap index worker supervision (ADR 0045).

## 0.7.0

### Added

- Anchored `IntervalTrigger.at` wall-clock schedules (`HH:mm`).
- `oka supervisor status|apply|check` CLI integration (in `oka` package).

## 0.6.0

- Initial release (ADR-0040 rung 1): `ComponentSpec`/`DesiredState` over
  the `resource_composition` substrate, pure convergence planner
  (service/job shapes, watch/interval triggers as properties), advisory
  `MachineRegistry` with cession-based kill policy, crash-only
  `Supervisor.converge` driver, and `supervisorFinding` evidence events.
