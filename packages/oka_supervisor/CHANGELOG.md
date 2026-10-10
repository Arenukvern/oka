# Changelog

## 0.6.0

- Initial release (ADR-0040 rung 1): `ComponentSpec`/`DesiredState` over
  the `resource_composition` substrate, pure convergence planner
  (service/job shapes, watch/interval triggers as properties), advisory
  `MachineRegistry` with cession-based kill policy, crash-only
  `Supervisor.converge` driver, and `supervisorFinding` evidence events.
