# ADR index

ADRs are for maintainers and agents changing architecture. Day-to-day usage
docs live in `README.md` and `docs/guides/build_and_config.md`.

| ID | Title | Status |
|----|-------|--------|
| [0000](0000-adopt-adr-and-doc-lattice.md) | Adopt ADRs + concept doc lattice | accepted |
| [0001](0001-no-gradle-default-build-path.md) | No-Gradle default build path; demote cargo-apk hybrid | accepted |
| [0002](0002-composable-build-pipeline.md) | Composable build pipeline (steps + YAML overrides + Dart composition) | accepted |
| [0003](0003-vector-first-launcher-icons.md) | Vector-first adaptive launcher icons (no PNG tooling) | accepted |
| [0004](0004-no-gradle-aab-bundle.md) | No-Gradle AAB via hand-assembled bundle (no bundletool) | accepted |
| [0005](0005-release-tooling-and-plugin-distribution.md) | Release tooling: release-please + one-version train; skills via plugin distribution | accepted |
| [0006](0006-dart-entrypoint-hooks.md) | Declarative Dart composition API as the single extension surface | accepted |
| [0007](0007-self-resolving-builds.md) | Self-resolving, self-checking builds | accepted |
| [0008](0008-dependency-plan-dry-run.md) | Dependency-plan dry-run (`oka explain --deps`) | accepted |
| [0009](0009-remove-cargo-apk-hybrid.md) | Remove the demoted cargo-apk hybrid completely | accepted |
| [0010](0010-typed-dart-project-config.md) | Typed per-project config in Dart (oka.yaml becomes optional) | accepted |
| [0011](0011-hot-reload-run-loop.md) | Agent-first dev loop: hot reload via the flutter_tools daemon protocol | accepted |
| [0012](0012-remove-embedded-ai-client.md) | Remove the embedded AI client; oka is agent-driven, not LLM-embedding | accepted |
| [0013](0013-toolchain-provisioning-artifact-store.md) | Toolchain, provisioning, and artifact store as composable surfaces; distribution targets are not platforms | accepted |
| [0014](0014-distribution-targets-secrets-model.md) | Distribution targets + three-tier secrets model (defines for app config, credential paths for build-host secrets) | accepted |
| [0015](0015-cli-verb-target-split.md) | CLI verb/target split and project-declared target discovery (`oka run`) | accepted |
