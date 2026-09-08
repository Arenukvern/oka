## Unreleased

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
