# Hot reload / hot restart — executable plan (ADR-0010)

This is the task breakdown for implementing `oka dev` per
[ADR-0010](../decisions/0010-hot-reload-run-loop.md). Agents execute; humans
steer. A phase is done only when its tests and evidence exist
([PHASE_CHECKLIST](../PHASE_CHECKLIST.md)).

## Shape of the feature (read first)

```
oka build apk --debug            # oka owns: assemble, package, sign (exists)
oka dev                          # oka owns: install → launch → session
  ├─ device layer                # adb install -r, am start, logcat URI scrape, adb forward (new)
  ├─ session manifest check      # flag parity: refuse on mismatch (new, H1)
  ├─ daemon adapter              # flutter attach --machine JSON over stdio (new, H3)
  └─ surfaces
      ├─ human: r / R / q keyboard loop, oka-rendered progress
      ├─ agent:  oka dev --json   (structured event stream on stdout)
      └─ agent:  oka dev --watch  (non-TTY watcher → reload/restart dispatch)
```

Division of labor: **oka owns build → install → launch and the entire event/
UX surface; flutter_tools owns the resident compiler, VM-service plumbing,
and reload/restart execution** — reached via its machine-readable daemon
protocol, never its TUI.

## Non-goals (do not build these)

- Incremental native DEX push / dex-hot-swap — impossible on Android; native,
  resource, and manifest changes always mean full `oka build` + reinstall.
- Profile/release support — debug (JIT) only; refuse loudly otherwise.
- DevFS or a DDS dependency.
- Reimplementing the frontend_server client (Option C) — gated behind a new
  ADR with measured evidence (see ADR-0010 §6).

## H0 — Prerequisite audit (evidence first)

**Goal:** prove the oka-built debug APK is hot-reload-capable before writing
feature code. Half a day.

- [ ] Verify debug APK contents: `kernel_blob.bin` present in
      `flutter_assets/`, no AOT `libapp.so`
      (`-dTrackWidgetCreation=true` is already passed in
      `flutter_assemble.dart` — assert it in a test).
- [ ] Manual evidence on a device + headless emulator: install oka-built APK,
      launch, `adb logcat` shows `Dart VM Service listening on
      http://127.0.0.1:<port>/<auth>/`, `adb forward` + a `vm_service`
      one-off script connects and calls `getVM`.
- [ ] Probe `flutter attach --machine` against the oka-built APK end-to-end
      (correctness probe, not shipped code). Record: does attach discover the
      service URI via logcat on its own? Does `flutter run --machine
      --use-application-binary <apk>` skip Gradle (check its output for
      Gradle invocations)? Record findings in the H0 evidence block below.
- [ ] Decide (one-line note in evidence): attach vs
      `run --use-application-binary` as the H3 integration point.

**Tests:** APK-content assertions (unit, no device); the VM-service probe is
manual evidence recorded here.

**Exit:** this evidence block filled; blockers documented.

> ### H0 evidence
> *(fill in — device/emulator logs, attach probe transcript, decision note)*

## H1 — Session manifest (flag parity subsystem)

**Goal:** make it impossible to attach a mismatched session to an oka-built
APK. Shared infrastructure — every later phase depends on it.

- [ ] `packages/oka_android/lib/src/dev/run_session.dart`: at build time,
      record `build/run_session.json` next to the APK: Flutter SDK path +
      engine revision (reuse what `flutter_assemble.dart`/`engine_artifacts.dart`
      resolve), target file, build mode, dart-defines (merged, normalized),
      package/app id, ABI(s).
- [ ] `RunSession.load()` + `validateAgainst(...)`: compare requested session
      (target/defines from CLI) against the manifest; on mismatch print an
      oka-branded error that names the exact differing fields and the fix
      (rebuild or align flags). Never warn-and-continue.
- [ ] `oka dev` resolves the flutter binary from the recorded SDK path —
      never `PATH`.

**Tests:** manifest round-trip; mismatch detection for each field; CLI↔
manifest normalization (e.g. `--dart-define=STORE=googlePlay` vs
`--dart-define-from-file` producing identical merged defines).

**Exit:** unit tests green; `oka build apk --debug` emits the manifest
(golden-file test).

## H2 — Device layer (adb)

**Goal:** oka owns install → launch → service reachability. New surface;
`ProcessRunner` (oka_core) exists; adb location comes from the Android SDK
locator already used for build tools.

- [ ] `packages/oka_android/lib/src/dev/adb_tool.dart`: device listing
      (`adb devices -l`), `install -r <apk>`, `am start` (resolve the
      launcher activity from the merged manifest oka already produces),
      `logcat` streaming, `adb forward tcp:0 tcp:<port>`.
- [ ] VM-service URI scrape: bounded-time logcat watcher keyed on
      `Dart VM Service listening on`; parse scheme/host/port/auth.
- [ ] `oka dev -d <device-id>` selection with a clear error when zero or
      multiple devices and no `-d`.
- [ ] Human-readable failures: "device unauthorized", "INSTALL_FAILED_*",
      missing platform-tools → map to oka-style next steps.

**Tests:** pure command-construction tests (mirroring `flutter_assemble.dart`
style); logcat-parser unit tests against recorded fixture logs; emulator
e2e marked and skipped when no emulator is available (CI follows
`PHASE_CHECKLIST` evidence rules — device tests need the emulator tier).

**Exit:** `oka dev --build --install --launch` (no session yet) works
end-to-end on emulator; evidence recorded.

## H3 — `oka dev` v1: daemon session (machine protocol)

**Goal:** working hot reload for humans and agents.

- [ ] `packages/oka_android/lib/src/dev/daemon_adapter.dart`: spawn
      `<sdk>/bin/flutter attach --machine` (integration point per H0
      decision) with session-manifest flags; speak the daemon JSON protocol
      on stdio: send `app.reload` / `app.restart` / `app.stop` /
      `daemon.shutdown`; receive events (`app.start`, `app.debugPort`,
      `app.started`, `app.progress`, `app.reloadRecommended`, errors).
      Feature-detect: ignore unknown fields/events (protocol is not
      semver'd); log at `-v` only.
- [ ] Replace the stub in `lib/src/cli/dev_command.dart`:
      - default (TTY): oka-rendered progress + `r` (reload), `R` (restart),
        `q` (quit); **no flutter_tools TUI passthrough** — oka renders.
      - `--json`: one structured event per line on stdout (machine stream,
        `pipeline_events.dart`-style envelope) for agents.
      - refuse profile/release; refuse on H1 manifest mismatch.
- [ ] Map daemon errors → oka diagnostics: reload failures and
      `app.reloadRecommended` events produce oka-branded messages (an agent
      must be able to act from the message alone).

**Tests:** daemon adapter against a scripted fake (stdio fixture: request/
response JSON lines) — no device needed for the protocol layer; emulator e2e
for the full loop.

**Exit:** on an emulator: edit Dart → `r` reloads; `oka dev --json` +
programmatic reload works headless (the agent-usable acceptance test);
evidence recorded.

> ### H3 evidence
> *(fill in — emulator transcript, headless `--json` reload transcript)*

## H4 — `--watch`: change classification & automatic dispatch

**Goal:** agents (and lazy humans) get reload-on-save with honest routing.

- [ ] File watcher (promote `watcher` to a direct dependency) over `lib/`,
      target file, `android/`, `oka.yaml`, assets — debounced.
- [ ] Classify: Dart-only → daemon `app.reload`; native/res/manifest/oka.yaml
      → **stop suggesting reload**: print "requires `oka build apk --debug` +
      reinstall" with the exact command; offer `--rebuild-on-native` to do it
      automatically (build → reinstall → relaunch → re-attach).
- [ ] `--watch` implies non-TTY-safe operation (no keyboard; `--json`
      compatible) — this is the agent default loop.

**Tests:** classification table tests (fixture trees); debounce tests;
e2e: edit Dart under `--watch --json` → reload event observed.

**Exit:** classification tests green; headless watch loop demonstrated on
emulator.

## H5 — Hot restart semantics & polish

**Goal:** restart behaves correctly and docs are true.

- [ ] `app.restart` mapping (full non-incremental kernel compile + restart —
      flutter_tools semantics; there is no `_flutter.hotRestart` RPC). Confirm
      state-loss messaging matches what actually happens.
- [ ] Update user-facing docs (`build_and_config.md` → Dev loop section,
      `quick_recipes.md`, README) — docs link to behavior, never paraphrase.
- [ ] `oka doctor`: add hot-reload readiness checks (debug kernel present,
      adb present, device reachable) so failures surface before `oka dev`.

**Tests:** restart e2e; doctor checks unit-tested.

**Exit:** PHASE_CHECKLIST entry for ADR-0010 moved to Done with evidence.

## Gotchas (encode these, regardless of phase)

- Debug (JIT) only — refuse profile/release loudly.
- Flag parity via H1 manifest; the flutter binary comes from the recorded SDK
  path, never `PATH`.
- The session must use the flutter SDK that produced the APK's
  `flutter_assets` (key off the engine revision already resolved in
  `flutter_assemble.dart`).
- Headless emulators/CI: software rendering flags to avoid GPU faults.
- The daemon protocol is not a semver contract: feature-detect, tolerate
  unknown fields, keep the protocol adapter the *only* file allowed to know
  daemon wire details.
- Hot reload is Dart-only. Native/res/manifest → full rebuild + reinstall.
  Never attempt dex push (ADR-0010 §5).
- Never wrap `flutter run`'s default path (it invokes Gradle for APK
  assembly) — only machine-mode consumption of a prebuilt APK or attach.
