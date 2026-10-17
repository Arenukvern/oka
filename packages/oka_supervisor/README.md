# oka_supervisor

Declarative supervisor (ADR-0040): steady-state convergence over the
[`resource_composition`](../resource_composition) substrate.

**TL;DR**: declare desired state as typed specs → run `converge` → it
observes, diffs, acts once, writes facts, exits. No daemon.

```dart
import 'package:oka_supervisor/oka_supervisor.dart';

const desired = DesiredState(specs: [
  ComponentSpec(
    id: 'api',
    providerName: 'leased', // mechanics live in the provider
    readiness: HandshakeLine(pattern: 'listening on'),
    policy: SupervisionPolicy(shape: SupervisionShape.service, maxRestarts: 3),
  ),
  ComponentSpec(
    id: 'nap-draft',
    providerName: 'chat',
    policy: SupervisionPolicy(shape: SupervisionShape.job),
    trigger: IntervalTrigger(period: Duration(hours: 6)),
  ),
]);

final supervisor = Supervisor(projectRoot: Directory.current.path);
final report = await supervisor.converge(
  desired: desired,
  factory: (name) => switch (name) {
    'leased' => LeasedProcessProvider(/* … */),
    'chat' => chatServeProvider,
    _ => throw ArgumentError(name),
  },
);
print(report.describe());
```

Laws (details in the ADR):

- **Convergence is explicit** — one `converge` pass per invocation; a
  resident supervisor is a gated later rung, never implicit.
- **Restarts are budgeted** — `maxRestarts` per `restartWindow`;
  exhausted → terminal `giveUp` finding; the reset is a `revision` bump.
- **Kill rights come from spawn lineage or cession** — records with
  `killPolicy: none` (hand-started processes) are observed, never
  signaled.
- **The machine registry is advisory** — `~/.oka/supervisor/records/`,
  atomic writes before spawn, scoped per project root.
- **Facts stay in the substrate envelope** — lifecycle events plus
  `supervisorFinding` rows in the same JSONL evidence stream.

Providers own all mechanics — spawn, probes, stop ladders. Use
`LeasedProcessProvider` (oka_core) for processes, your own
`ResourceProvider` for anything else. `FakeProvider`
(resource_composition) scripts deterministic tests.

Read-only foreign projections: codemap's declared command lanes
(codemap ADR-0034) project into supervisor findings without ever
executing a declaration (ADR-0041 law 7 — the supervisor owns the
schema, not the implementation language).

```bash
cd packages/oka_supervisor && dart run tool/codemap_projection.dart \
  --snapshot lanes.json --receipts receipts/ --check
```

`--snapshot` is codemap's data form (`{"lanes": [...]}`, e.g. the
`run_lanes.py --list` audit capture); `--receipts` is wherever a
runner stdout capture landed (JSONL or saved `--once` JSON; the
file's mtime is the receipt time — receipts carry no wall clock).
Per-lane findings: `ready | overdue | unrun | unknown |
corruptReceipt`; `--check` exits 1 on overdue/unrun/corruptReceipt —
the future CI hook (ADR-0041 rung 2).

Runnable demo (real process, start → ready → crash → restart → facts):

```bash
cd packages/oka_supervisor && dart run example/supervise_demo.dart
```

Dev tip: the test suite contains a real-process end-to-end
(`converge_real_process_test.dart`) — a `/bin/sh` service converging to
ready and a crashing command climbing the ladder to `giveUp`.

Codemap index lifecycle ([ADR-0045](../../docs/decisions/0045-codemap-index-worker-supervision.mdx))
is an explicit native worker recipe, separate from read-only lane projection:

```dart
final recipe = CodemapIndexRecipe(
  executable: '/path/to/codemap-mcp',
  projectRoot: '/path/to/project',
  scope: {'exts': ['.py', '.dart'], 'ignore_prefixes': ['build/']},
);
final provider = recipe.provider();
final report = await Supervisor(projectRoot: recipe.projectRoot).converge(
  desired: recipe.desired,
  factory: (_) => provider,
);
```

The handshake means observation established. Inspect `provider.health(ref)`
for semantic `ready | pending | blocked | unknown`; pending/blocked inputs never
request process restarts. Receipt identity and heartbeat are checked before
trusting revision claims. Native Codemap owns scope, invalidation and refresh;
Oka owns process leases and existing restart budgets. Desired state includes the
resolved executable target and SHA-256 of its bytes; evaluate `recipe.desired`
on every convergence pass. Atomic replacement causes an owned revision restart
using existing budget-reset policy; it grants no rights over foreign processes.
The finite runner reevaluates both desired identity and provider every pass.

Explicit finite convergence runner:

```bash
dart run tool/codemap_index.dart --root /path/to/project \
  --executable /path/to/codemap-mcp --passes 30 --interval-ms 1000
```

`--stop` requests teardown through the recorded owned lease. Scheduling another
finite run is caller-owned; this tool does not authorize the resident rung.
