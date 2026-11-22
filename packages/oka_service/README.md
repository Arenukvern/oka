# oka_service

Non-GUI buildables for [oka](https://github.com/Arenukvern/oka) (ADR-0055):
a generic command pipeline driving `jaspr build`, `dart compile exe`,
`docker build`, or any argv sequence — plus a GitHub Releases publish
channel. Tiny, framework-agnostic.

```dart
import 'package:oka_service/oka_service.dart';

Delivery(
  name: 'cli-release',
  pipeline: CommandPipeline(
    platform: 'cli',
    commands: [CommandSpec('dart', ['compile', 'exe', 'bin/cli.dart'])],
    artifactId: 'cli-binary',
    artifactPath: 'build/cli',
  ),
  channel: GitHubReleasePublishTarget(
    repository: 'owner/cli',
    tag: 'v1.2.3',
  ),
)
```

`CommandPipeline` is an open platform pipeline: it stops at the first
failing command and resolves the declared artifact path for downstream
steps. `GitHubReleasePublishTarget` uploads a release asset with the `gh`
CLI under oka's publishing laws — dry-run by default (the plan prints
exactly what a real upload does, credential-free), ambient `gh` auth only,
no stdin, no secret values in state.
