## 0.8.0

- Bound aggregate direct process observations with configurable
  `observationBudget` (default two seconds); count startup identity time against
  the run deadline and refuse signals when startup identity is unavailable.
  Late readonly results cannot resume an expired stop; kill adapters remain
  awaited and adapter resource cleanup remains their responsibility.

- Return failed deadline teardown receipts while a root remains unresolved,
  preserving its captured identity and explicit `rootExitObserved`; avoid
  waiting indefinitely after returned discovery failure. Timeout diagnostics
  distinguish verified cleanup from unverified survivors (ADR-0046).
  Keep bounded output draining until unresolved root exit so closing a live
  writer's pipe cannot become an accidental termination path. Expose the
  existing process platform seams on `SystemProcessRunner` for composition.

- Retain pre-signal descendants across reparenting; bind each teardown signal
  to its captured identity, and report post-signal discovery loss as unknown.
- Await deadline tree teardown in `runBoundedProcess` after root exit; expose
  `teardownVerified` and unverified cleanup details instead of a premature
  empty-survivor result.

- Stop a newly spawned managed process when its lease cannot be persisted;
  report the original persistence error and whether teardown was verified.
  Refuse startup-failure signals when the live root has no captured identity.

- Add explicit `LeasedProcessProvider.runToExit` for job completion: await exit zero,
  fail nonzero exits, and stop the owned tree on cancellation.
- Keep ready service output drained until process exit; retain leases after an
  unverified stop and protect replacement leases from stale cleanup. Inspection
  now distinguishes matching, recycled and unverifiable process identities.
## 0.7.0

### Changed

- Release train alignment with `oka` 0.7.0.

## 0.4.0

### Added

- `AndroidBuild.r8Rules` (`android.r8_rules`): inline, per-app R8/ProGuard
  rules applied after `proguard_files`; vendor-neutral platform defaults.

- Tree-aware process seam (ADR-0026 decision 8): `ProcessTreeProbe` /
  `HostProcessTreeProbe` descendant enumeration, `stopProcessTree`
  (enumerate before the first signal; graceful→force ladder; verified
  death; recycled-root refusal), and `runBoundedProcess` — a bounded run
  whose deadline kills the spawned tree instead of abandoning it, with
  bounded output capture and a terminal cause.

### Changed

- `SystemProcessRunner` deadline enforcement now kills the child process
  tree before raising `TimeoutException`; the exception contract is
  unchanged, but no child is abandoned on timeout.

## 0.2.0

- Add composable `CacheDiagnostics` providers, typed reports and partial,
  read-only registry inspection. PID-zero leases remain unknown and preserved.

- Add a persistent cache project registry, best-effort build registration and
  saved cleanup plans that revalidate current ownership and filesystem state.

- Add platform-neutral storage inventory and preview/apply pruning contracts,
  with overlap accounting, protected locations and filesystem safety checks.
- Fix absent-store GC, include extracted payload bytes and count only successful
  deletions; reject sweep paths that escape the shared store.

- Release the platform-neutral `Target.explainDetails` hook used by web targets.

- Directory-artifact convention (ADR-0016 W2): `PublishTarget.artifactIsDirectory`
  (default `false` — file targets unchanged) and `PublishPlan.artifactIsDirectory`
  (typed flag in plans, JSON round-trip, `describeLines` marks
  `artifact … (directory)`). `auditPublishConformance` now asserts the
  declared artifact kind when the artifact path exists on disk: a
  directory-artifact target must point at a directory, a file target must
  not point at a directory.

## 0.1.6

- Typed `AndroidBuild`/`FlutterBuild` config values with `copyWith` and
  `toConfigMap` (ADR-0010); `PlatformPipeline.configOverrides` seam and
  `mergeConfigMaps` precedence (Dart config > oka.yaml > defaults).
- `Pipeline.run` accepts a pre-seeded `PipelineState` (runtime scope).
- Entry-point discovery helper (`findPipelineEntrypoint`).

## 0.1.5

- Declarative composition root (`Oka`, `PlatformPipeline`), typed artifact
  pipeline, `okaRun` entrypoint (ADR-0006).
