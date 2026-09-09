# Evidence: hot reload / hot restart on device, verified via flutter_mcp_cli

Date: 2026-09-07 · Device: emulator-5554 (h0test AVD; physical Galaxy A55
tested earlier the same day) · App: example (debug, no-Gradle build)

## Method

`oka dev --json -d <id>` compiles + syncs (the only path that compiles
edited Dart — a raw VM-service reload is a kernel no-op) and emits
`session.ready` with the forwarded `wsUri`. `flutter_mcp_cli` (from
mcp_flutter) attaches to that URI and reads the Flutter **semantics tree**,
which uiautomator cannot (Flutter renders text via Skia).

Discovery is the spec-v2 runner-session file: `oka dev` writes
`.flutter_mcp/runner-session.json` at `session.ready` (with the
`runner: "oka-dev"` display field) and deletes it on exit — oka is the
first conforming runner of the toolkit-neutral Dart dev session contract;
the toolkit's adapter consumes the file (`--runner-session-file`
overridable) and never learns oka's name. Internal `vm.uri` verification
tools keep reading `.oka_cache/dev/vm.uri`.

## Transcript facts

1. `reload.result {"ok":true}` after editing `lib/main.dart` — semantic
   snapshot shows the new app-bar title (`'Reload v4 via fifo'`).
2. Tap FAB twice via `tap_widget` → semantics counter reads `'2'`.
3. `restart.result {"ok":true}` → counter back to `'0'` (state loss =
   hot restart semantics) while the title stays `'Reload v4 via fifo'`
   (code persists).

## Division of labor (the important finding)

- **oka dev** owns compile + sync + reload/restart (daemon protocol).
- **flutter_mcp_cli** is the verification/interaction oracle: semantic
  snapshots, taps, screenshots, app errors — agent-readable.
- Its own `hot_reload_flutter` reports success without compiling — a no-op
  if sources changed. Do not use it as the reload driver.

Earlier physical-device (Galaxy A55) session: reload ok; `app.restart
fullRestart:true` on attach stopped the app (emulator: fine) — tracked as a
follow-up for the dev session's restart handling.
