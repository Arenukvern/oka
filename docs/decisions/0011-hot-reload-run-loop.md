# 0011 — Agent-first dev loop: hot reload/hot restart via the flutter_tools daemon protocol

- **Status:** accepted
- **Date:** 2026-09-06
- **Decision-makers:** Anton, oka agent
- **Extends:** 0001 (no-Gradle default build path), 0002 (composable pipeline)
- **Executable plan:** [docs/guides/hot_reload_plan.md](../guides/hot_reload_plan.md)

## Context

oka's north star is agentic workflows: "an agent can fix a broken build from
oka's error messages alone" ([why this repo matters](../start_here/why_this_repo_matters.md)).
The build side is done; the **dev loop** is not — `oka dev` is a stub that
tells users to fall back to `adb install` + `flutter attach`.

Hot reload decomposes into five mechanisms:

| # | Mechanism | Owner today |
|---|---|---|
| 1 | JIT debug APK (`kernel_blob.bin`, `-dTrackWidgetCreation=true`) | ✅ oka (`flutter_assemble.dart`) |
| 2 | Launch with VM service enabled; scrape service URI + auth code from logcat | ❌ flutter_tools |
| 3 | Reach the VM service (adb forward/reverse) | ❌ flutter_tools |
| 4 | Resident kernel compiler (frontend_server, incremental dill deltas) | ❌ flutter_tools |
| 5 | VM-service client / session loop (`reloadSources`, `ext.flutter.reassemble`, restart) | ❌ flutter_tools |

The Phase-0 invariant bans Gradle / `flutter build apk` as the default build
path — it does **not** ban flutter_tools binaries (oka already shells out to
`flutter assemble` on the default path). The real design question is not
"delegate or not" but **which contract we delegate and which surface we own**.

### The two contract types (the decisive distinction)

- `flutter assemble` is a **batch, non-interactive CLI** with stable argv and
  parseable stdout. Delegating it is proven safe.
- `flutter attach`'s default interface is an **interactive TUI keystroke loop**
  (`r`/`R`/`q`), explicitly not a stable contract. Its output is not designed
  for machine consumption.

oka's primary user — an AI agent — cannot press `r` in a TTY. Any option whose
only control surface is attach's TUI is unusable by the primary user except
via fragile PTY driving.

### The critical insight: the VM service is the easy 20%

`reloadSources` (kernel bytes travel over the RPC — no adb push) +
`ext.flutter.reassemble` are simple calls. The hard 80% is the **resident
frontend_server** (incremental compile against the previous dill, protocol
specced only by flutter_tools internals, version-locked). Any option that
avoids reimplementing #4 avoids most of the cost and risk.

## Options considered

| Option | Machinery owner | Agent-usable? | Contract stability | Cost |
|---|---|---|---|---|
| A. `oka dev` execs `flutter attach` (TUI) | flutter_tools | ❌ humans only | TUI — none | trivial |
| B. Drive attach's TUI via PTY | flutter_tools | ⚠️ hack | TUI — none | moderate, fragile |
| C. Full DIY resident runner in oka | oka | ✅ | none to rely on | weeks; version-locked to engine internals |
| D. **Embed the flutter_tools daemon** (`flutter attach --machine` / `flutter run --machine`) | flutter_tools (#2–5) | ✅ native | JSON daemon protocol — purpose-built for embedding (this is what VS Code/IntelliJ use) | small–moderate |

Notes:

- **A** was the leading candidate in an earlier evaluation. It fails the
  primary-user test: no batch, non-TTY path to trigger a reload. Rejected as
  the main path; retained as a human-facing escape hatch (`oka dev --tui`).
- **B** admits the TUI is not a contract, then depends on it anyway. Rejected.
- **C** pays the full version-lock cost of `ResidentRunner`/`resident_compiler`
  for near-zero differentiation *today*. However, owning the resident compiler
  is the only way to (a) overlap the initial kernel compile with
  packaging/install (attach starts strictly after install, so its 2–5 s
  initial compile is always serial on the critical path) and (b) keep a warm
  compiler daemon across `oka build`/`oka dev` invocations. That is a real
  future win — but it must be *evidence-driven*, not assumed.
- **D** delegates mechanisms #2–5 to flutter_tools over its machine-readable
  daemon protocol, while oka owns build → install → launch and the entire
  event/UX surface. JSON commands (`app.reload`, `app.restart`, …) and events
  arrive on stdio — batch-friendly, TTY-free, and far more deliberate than
  the TUI.

### Decision criterion (explicit)

The primary criterion is **agent-usability of the control surface** (headless,
non-TTY reload triggers, structured events oka can parse, route, and improve),
not latency. Latency differences between options are seconds; control-surface
differences are categorical. Secondary criteria: contract stability, and the
surface area of flutter_tools internals oka couples to.

## Decision (accepted)

**Option D — hybrid: oka owns everything except the Dart VM session;
the session runs over the flutter_tools daemon protocol; oka owns the
interface to it.**

1. **oka owns the device layer**: build (existing), `adb install -r`,
   `am start`, logcat service-URI scrape, `adb forward`. No Gradle anywhere.
2. **The session is `flutter attach --machine`** (fallback explored in H0:
   `flutter run --machine --use-application-binary <apk>`, which skips Gradle
   for a prebuilt APK — decide with evidence which discovery path is
   sturdier). oka speaks the daemon JSON protocol on stdio and maps events
   onto oka's structured event surface (`pipeline_events.dart` style).
3. **oka owns the UX for both audiences**:
   - Humans: keyboard loop (`r`/`R`/`q`) and human-readable progress —
     rendered *by oka*, from daemon events, not by attach's TUI.
   - Agents: `oka dev --json` (machine event stream on stdout) and
     `oka dev --watch` (non-TTY file watching + automatic reload/restart
     dispatch + oka-branded diagnostics when a change requires a full rebuild).
4. **Flag parity is a subsystem, not a gotcha.** `oka dev` may only attach to
   an APK whose build fingerprint matches the session it requests. The build
   records (Flutter SDK path + engine revision from `flutter_assemble.dart`,
   target, build mode, dart-defines) into a session manifest; `oka dev`
   validates and replays them, and **refuses loudly on mismatch** — a
   mismatched attach silently compiles a kernel that corrupts the running
   app, failing at runtime, not at command time.
5. **Scope cuts (accepted):**
   - **No incremental native DEX push.** Android's runtime cannot hot-swap
     classes in an installed APK; native/res/manifest changes always route to
     a full `oka build` + reinstall. (The archived plan's Phase 4.4 is
     rejected.)
   - **Debug (JIT) only.** Profile/release refuse `oka dev` loudly.
   - **No DevFS, no DDS dependency.** Not needed for the Android
     daemon-protocol path.
   - `_flutter.hotRestart` (as written in the archived plan) does not exist;
     hot restart is a full non-incremental kernel compile + app restart
     handled by the daemon (`app.restart`).
6. **Escalation path to Option C is open but gated.** If, after H3/H4
   evidence (see plan), the daemon protocol proves limiting (missing events,
   latency that matters, SDK-version breakage), a **new ADR** proposing a
   minimal DIY resident compiler (frontend_server client + `reloadSources` +
   `reassemble`, no DevFS/DDS) is required before coding. It must be justified
   by the compile/build-overlap and warm-daemon wins, measured, not assumed.

## Consequences

Good: agents get a first-class, headless, structured reload loop; humans get
a real `oka dev`; zero kernel-compiler code to maintain; every upgrade risk
is concentrated in one protocol adapter; the no-Gradle invariant is
untouched (attach/run in machine mode never invokes Gradle when consuming a
prebuilt APK).

Bad / Neutral: oka couples to the flutter_tools daemon protocol (stable in
practice — IDEs depend on it — but not semver'd; pin + feature-detect +
tolerate-unknown-fields, and keep `--tui` escape hatch); initial compile is
serial after install until/unless Option C is justified later; hot-restart
semantics follow flutter_tools, not a custom contract.

**Authoritative source:** `lib/src/cli/dev_command.dart`,
`packages/oka_android/lib/src/` (device layer, session manifest),
[hot reload plan](../guides/hot_reload_plan.md).
