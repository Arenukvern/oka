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
