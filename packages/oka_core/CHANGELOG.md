## 0.1.6

- Typed `AndroidBuild`/`FlutterBuild` config values with `copyWith` and
  `toConfigMap` (ADR-0010); `PlatformPipeline.configOverrides` seam and
  `mergeConfigMaps` precedence (Dart config > oka.yaml > defaults).
- `Pipeline.run` accepts a pre-seeded `PipelineState` (runtime scope).
- Entry-point discovery helper (`findPipelineEntrypoint`).

## 0.1.5

- Declarative composition root (`Oka`, `PlatformPipeline`), typed artifact
  pipeline, `okaRun` entrypoint (ADR-0006).
