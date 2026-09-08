# oka_core

Core contracts for [oka](https://github.com/Arenukvern/oka) — the no-Gradle
build system for Flutter Android: typed build context, composable
`BuildStep` pipeline with typed artifact exchange (`Artifact<T>`,
`requires`/`provides`), the declarative `Oka`/`PlatformPipeline` composition
root, and `okaRun` for project-side pipeline entrypoints (ADR-0006/0010).

Dependency-light by design (no CLI/AI surface) so host apps with strict
`dependency_overrides` can pin it for Dart pipeline hooks.

See the [docs](https://docs.page/arenukvern/oka) and the
[design decisions](https://github.com/Arenukvern/oka/tree/main/docs/decisions).
