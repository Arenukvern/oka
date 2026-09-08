# 0017 — Browser session targets + the session-handle artifact convention

- **Status:** accepted
- **Date:** 2026-09-08
- **Decision-makers:** Anton, oka agent

## Context

Testing web builds today depends on who launches the browser. Flutter-tool
launches Chrome itself (`flutter run -d chrome`) with a one-browser, one-
page, one-app model — fine for interactive dev, structurally unable to
express: pinned pre-stable feature flags (the WebMCP projection used by
`mcp_flutter`/intentcall requires
`--enable-features=WebModelContext --enable-experimental-web-platform-features`),
headless test batteries, multiple concurrent sessions, or the mesh case
(the same app alive in several browsers at once, cross-engine). The real
evidence lives in consumer repos as shell glue: `run_web_showcase.sh`
hand-pipes `--web-browser-flag` strings, greps `WS_URI=` out of stdout, and
fakes detach/teardown in bash; `webmcp_command.dart` re-implements CDP port
discovery. This is the launch-script twin of the store-branch drift
ADR-0016 killed — untyped, duplicated per consumer, agent-hostile.

Meanwhile the **Android emulator already proves the shape in-repo**:
`EmulatorTarget` (`oka_android/lib/src/dev/emulator_target.dart`) is a
typed, composable ADR-0015 target — idempotent ensure-running (reuse a
running instance, never wipe userdata unless asked), pure scripted-fake-
testable command construction, and a handle artifact (`emulator-serial`)
that downstream steps consume as `-s` without knowing how the emulator got
there. Browser sessions are the **second instance of this pattern**, not a
new mechanism. (iOS simulator via `simctl` is the visible third.)

Engines also differ in capability, and the difference is *declared*:
Chromium speaks CDP; Servo speaks partial WebDriver; Ladybird has no debug
protocol yet. A design that assumes CDP everywhere is wrong at the same
depth as one that assumes Gradle.

## Decision

Chosen: **browser sessions as composable targets (`oka_web`), Chrome
first; a thin session-handle artifact convention shared across all session
kinds; test matrices explicitly deferred.** No `Session` base class — the
unifying contract is oka's existing `Target` + artifact DAG (ADR-0002/0015)
plus a naming convention, nothing more.

### 1. Two seams, same law as the web shell (ADR-0016)

- **`BrowserSessionSpec`** — the *what*: a typed, const-constructible
  value. Binary path (or provisioned binary ref, later), launch flags,
  debug port, headless, `profilePersistence` (ephemeral temp dir for test
  sessions vs persistent for dev), boot timeout, window size. No hidden
  merging; users compose specs in the entrypoint (ADR-0010).
- **`BrowserLauncher`** — the *how*: replaceable seam, three
  implementations:
  1. **`okaOwned` (default goal)** — oka spawns the binary with
     `--remote-debugging-port`, an ephemeral profile dir, and the spec's
     flags; readiness = HTTP probe of CDP `/json/version` (plain
     `dart:io` HttpClient — this is a readiness probe, **not** a CDP
     client; CDP protocol logic stays out of oka). Idempotent: a CDP-
     answering port is reused, matching `EmulatorTarget` reuse semantics.
  2. **`flutterDelegated` (migration path, explicitly temporary)** — oka
     computes flags and hands them to `flutter run -d chrome
     --web-browser-flag=...`. Exists because day-one cost; it cannot
     express multi-session or mesh and is documented as scaffolding, the
     same way the inject emitter is.
  3. **`plainServeUrl`** — print the URL, open whatever; the "dashboards
     stay a valid path" escape.

### 2. The session-handle artifact convention (the whole unification)

All session-producing targets (emulator, browser, future simulators/
containers/server processes) name their artifacts:

- `session-<name>-handle` — opaque primary handle (adb serial, debug URL,
  container ID, …); typed `Artifact<String>`
- `session-<name>-<sub>` — engine-specific sub-handles where they exist
  (`session-<name>-cdp-port`, `session-<name>-web-port`)

Downstream steps consume artifacts and never know the session kind. An
`EmulatorTarget` conforming alias for `emulator-serial` is a cheap,
non-breaking follow-up (the Android side needs no behavior change).

### 3. Chrome first, capability-declared

- `ChromeSessionTarget` ships in `oka_web` (`lib/src/session/`), target
  name `chrome-session`, producing `session-chrome-<name>-handle` +
  `session-chrome-<name>-cdp-port`.
- Chromium-only launch args are pure, tested functions (house style:
  `avdManagerCreateArgs`); unknown flags fail closed with the accepted
  surface named.
- A first-party `chromeWebMcp` profile const ships the two WebMCP flags
  with dartdoc marking intentcall's toolkit as source of truth and the
  feature as pre-stable. Oka owns the *configuration value*; the WebMCP
  protocol, `modelContext` negotiation, and any CDP client logic remain in
  the toolkit — the ADR-0016 boundary (oka never absorbs runtime probing)
  is unchanged.
- Servo/Ladybird are deferred: they need only the same seam with a
  different launcher + capability declaration (`debugProtocol: none |
  webdriver | cdp`), not new architecture. The `DebugProtocol` field is
  part of the spec from day one so deferral costs nothing later.

### 4. Named profiles are third-party contribution surface

The same law as ADR-0016 §3: intentcall (or any package) may ship const
`BrowserSessionSpec`s the way store packages ship shell contributions.
Session targets are to runtimes what publish targets are to stores — one
contract, many instances, third parties welcome.

### 5. Lifecycle scope, named not subclassed

Every session target carries the emulator's already-proven semantics plus
one axis: **long-lived** (dev loop; profile persists; session survives the
command) vs **ephemeral** (test session; temp profile dir; unconditional
teardown). A parameter, not a type hierarchy.

### Out of scope (explicit)

- **Test matrices / mesh** (N concurrent sessions, cross-session
  rendezvous, failure isolation, teardown-on-partial-failure) — deferred
  to a future ADR. It needs only the handle convention to exist; browser
  evidence comes first. The mesh case is recorded as the motivating
  evidence for that future ADR, not designed here.
- A `Session` base class or `oka_session` framework package.
- CDP client logic, WebMCP protocol negotiation — stay in the toolkit.
- Browser binary provisioning (chrome-for-testing / servo nightlies into
  the ADR-0013 store) — B1 follow-up; day one consumes an explicit binary
  path or well-known install.
- Linux headful-in-CI (xvfb) — launcher concern, deferred with evidence.

## Alternatives considered

- **Keep flutter-tool as the only launcher** — rejected: its model is
  one-browser/one-page; pinned-flag, headless-battery, and mesh cases are
  structurally inexpressible; evidence is shell glue in consumer repos.
- **A `DeviceSession`/`Session` base class now** — rejected: surfaces
  diverge (stateful AVD creation vs stateless binaries vs future image
  builds); a union base class breeds `kind ==` callsites. The `Target` +
  artifact contract already unifies; the handle convention is the only
  shared surface needed. Revisit at the third instance (simulator/
  container) as a *documented contract*, not a class.
- **CDP client in oka to verify WebMCP liveness** — rejected: runtime
  protocol probing belongs to the toolkit (ADR-0016 out-of-scope line);
  oka's `/json/version` probe is a readiness check, nothing more.
- **Browsers as a `PlatformPipeline`** — rejected for the same reason as
  ADR-0016: web compile stays delegated; sessions are runtime targets, a
  different axis entirely.

## Consequences

Good:
- Store-branch→targets symmetry completes: launch scripts (`run_web_showcase.sh`,
  its grep-the-stdout test harness) collapse into declarative, composable,
  agent-operable targets with `oka explain` renderability.
- The handle convention makes the future matrix ADR a pure composition
  problem (it consumes handles), with zero changes to session targets.
- `EmulatorTarget` is recognized as instance one; iOS simulator and
  container sessions become copy-the-house-style work, not design work.
- Chrome-only B0 keeps the first slice small: one engine, one launcher,
  pure args functions, scripted-fake tests — no new dependencies.

Bad / Neutral:
- The default binary discovery (well-known Chrome install paths per OS) is
  host-shape-dependent and will need doctor integration + provisioning
  (B1) before CI is hermetic.
- `flutterDelegated` persists as migration surface until okaOwned covers
  the dev loop end-to-end — a standing "temporary" that must be retired on
  evidence, not drift.
- `session-<name>-handle` is a cross-package naming contract from day one —
  renaming later would break consumers; it is frozen here deliberately.
- Two engines (Servo, Ladybird) remain unproven against the seam; their
  launchers may still surface capability-model gaps.

## Phased plan

Tracked in `docs/PHASE_CHECKLIST.md` (S0–S2).

- **S0 — Chrome session target (oka_web)**: `BrowserSessionSpec` +
  `DebugProtocol` + `profilePersistence`, okaOwned launcher (spawn +
  `/json/version` readiness probe + idempotent reuse + ephemeral teardown),
  `chrome-session` target producing `session-chrome-<name>-handle` /
  `session-chrome-<name>-cdp-port`, `chromeWebMcp` profile const, pure
  args construction, scripted-fake + unit tests, leakage gate stays green.
  Gate: this ADR.
- **S1 — doctor + provisioning**: browser detection in `oka doctor`
  (installed engines, versions, flag support), chrome-for-testing
  provisioning via the artifact store (ADR-0013). Gate: S0.
- **S2 — dev-loop + delegated retirement**: `oka dev` composes a
  long-lived chrome session; flutterDelegated shrinks to the documented
  migration path; EmulatorTarget handle-alias conformance. Gate: S0 +
  dev-loop evidence.
- **Future ADR — session matrices / mesh** (N concurrent cross-engine
  sessions, rendezvous artifacts, teardown policy). Gate: S0 evidence +
  the mesh motivating case.
- **Future instances — containers & server processes.** The
  `session-<name>-handle` convention extends to runtime environments
  beyond browsers: `apple/container` / Docker container sessions
  (provisioning = container images via the ADR-0013 artifact store;
  handle = container ID + mapped ports; enables testing oka itself and
  Dart packages on Linux) and Dart server process sessions (handle =
  base URL + health probe; enables intentcall/mcp-server targets). Each
  arrives as an independent target conforming to the convention — no
  base class (§ Out of scope). Gate: S0 evidence + a lightweight
  checkpoint per instance, not a framework.

**Authoritative source:** `packages/oka_web/lib/src/session/` (once S0
lands), this ADR, `docs/PHASE_CHECKLIST.md` (progress).
