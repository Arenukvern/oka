# Build hardening roadmap

Complications surfaced by the first production e2e (`last_answer`, Sep 2026),
each classified: **SDK** (typed API surface), **CHECK** (doctor / dry-run /
post-build lint), or **AUTO** (oka resolves without config). Design law for
all of it: composability — every capability is a `BuildStep`, a typed value,
or a resolver service. No YAML sprawl, no stringly flags.

## 1. SDK

| Item | Origin | Shape |
|---|---|---|
| `MavenResolver` service | parent-POM/BOM/scope fixes were regex patches inside `dependency_cache.dart` | Extracted resolver: POM graph walker (parent chain, BOM imports, dependencyManagement, properties), parallel BFS, per-artifact failure isolation, memoization. `DependencyCache` remains the facade (disk cache + AAR payload) |
| `MavenRepoRegistry` | `com.google.mlkit` silently routed to repo1 by a hardcoded prefix in two places | One declarative group-prefix → host map; user-extensible via config; unit-tested |
| Single `MavenCoordinate` | two types collided (ambiguous barrel export; probe compile errors) | Typed class lives in `oka_core`; `dependency_cache` re-exports |
| `ProcessRunner` | direct `Process.run` scattered; no default timeouts | Injectable runner in `oka_core` (`SystemProcessRunner`); adopted by resolver + new steps; toolchain migration ongoing |
| `PipelineEvent`s | progress invisible in logs; hang vs slow indistinguishable | `Pipeline.run(..., onEvent:)` emits typed events (step start/finish, cache hit, tool invocation, warning); CLI prints; future TUI/CI subscribes |
| `StepCache` → core | built ad hoc for five steps | `oka_android` keeps `StepCache`; validator-callback pattern is the contract for output liveness |
| Gradle parser corpus | `add("impl", …)` and conditional blocks missed | Fixture files from real pub-cache plugins under `test/fixtures/gradle/`; conditional-block deps flagged `inConditional` |

## 2. Checks

- **`oka build --dry-run` / `oka explain`** — compose the pipeline, validate the
  artifact chain, print steps + requires/provides, ABIs, signing resolution,
  version injection, defines, plugin list (discovery is file-only), dependency
  plan — **zero tool invocations**. The single biggest diagnosis lever found in
  practice: full builds were the only diagnosis tool for hours.
- **Dependency-plan dry-run** (`oka explain --deps`, [ADR-0008](../decisions/0008-dependency-plan-dry-run.md)) —
  resolves the declared plugin dependency plan through the resolver service:
  cache-only by default (offline-safe, misses reported `⚠️`); `--network` opts
  into full resolution where hard failures exit 1. Shares the declared-deps
  collector with plugin packaging so plan and build cannot disagree.
- **Post-build lint** (`PostBuildLintStep`, a normal composable step):
  - manifest `versionCode`/`versionName` actually present (badging parse)
  - debug-signed release artifact → hard fail unless `--allow-debug-signing`
  - size budget `pipeline.max_size_mb` → fail
  - `BundleConfig.pb` carries a bundletool version (byte check)
  - duplicate-class pre-warning across dex inputs
- **`oka doctor`** additions: kotlin/bundletool/JDK presence, repo reachability
  (HEAD with identity encoding — the gzip-hang class), package_config
  staleness, Maven cache state.

## 3. Auto-resolve (ADR-0007 policy)

| Trigger | Automatic action | Escapes |
|---|---|---|
| dev-only plugin (`dev_dependencies`) | excluded from release builds; included in debug | `pipeline.exclude_plugins` superset; ADR-0007 |
| `oka.yaml` lacks version | read `version: x.y.z+nn` from pubspec | explicit `version_code`/`version_name` wins |
| plugin sources need newer Java than config | bump `java_version` to detected max + warning | explicit `java_version` honored when >= detected |
| kotlinc/bundletool missing | auto `oka get <tool>` with printed notice | `OKA_NO_AUTO_INSTALL=1` |
| stale package_config | silent `flutter pub get` + log | — |
| packaging guess wrong / versionless POM deps / BOM chains | resolver fallbacks | — |
| dex part accumulation | dex dir cleaned per run | — |

Policy (ADR-0007): automatic with loud notices; escapes are env/flag, never
new YAML fields.

## 4. Meta-learnings

- Source-contract tests broke on every file move → prefer API assertions; keep
  path-contract tests in one place.
- Probe-ability (running a single step against a scratch dir) turned 10-minute
  loops into 30-second ones → `oka debug step <name>` formalizes it.
- Refactor claims should be checkable → `oka compare <apk1> <apk2>`
  (badging/entry diff) backs the byte-equivalence gate.
- A failing host app graph (broken sibling checkouts) must be reported as
  "unresolved in *your* dependency", not as raw kernel output.
