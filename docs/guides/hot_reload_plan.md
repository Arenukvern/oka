# Hot reload / hot restart — executable plan (ADR-0011)

This is the task breakdown for implementing `oka dev` per
[ADR-0011](../decisions/0011-hot-reload-run-loop.md). Agents execute; humans
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
> Filled 2026-09-07 (dev machine: Apple Silicon macOS, fvm Flutter beta
> 3.47.0-0.4.pre, engine `f88005a259ba379c2c1156178aa1870936be7b7f`,
> oka-managed SDK `~/.oka/android-sdk`). No item remains blocked — an
> emulator was provisioned non-interactively and the full chain was probed
> live.
>
> **1. Debug APK contents (static, real builds).**
> `example/.oka_cache/build/debug/app-debug.apk` (oka-built, no-Gradle):
> zip contains `assets/flutter_assets/kernel_blob.bin` (46,221,080 bytes),
> `isolate_snapshot_data` (11,647,016), `vm_snapshot_data`,
> `lib/arm64-v8a/libflutter.so`, `lib/armeabi-v7a/libflutter.so`; **no
> `libapp.so` anywhere** (debug = JIT). `-dTrackWidgetCreation=true` is
> passed in `flutter_assemble.dart` and asserted in
> `test/adr0011_apk_contents_test.dart`, which also rebuilds a minimal
> fixture through the real default pipeline when SDKs are present and
> re-asserts the same zip contract (skip-with-reason otherwise).
>
> **2. Emulator install → launch → logcat → forward → getVM (live).**
> Provisioned headless AVD (API 34, google_apis arm64) and ran the real
> chain — note the item below *discovered a Flutter wording change*:
>
> ```
> $ cd example && oka run device
> 📲 Installing app-debug.apk → ✅ Installed
> 🚀 Starting com.example.example.MainActivity
> ✅ Process alive (pid 5910)
> ✅ No failure signatures in device log
>
> $ adb logcat -d | grep -i "vm service"
> I/flutter ( 5910): The Dart VM service is listening on
>     http://127.0.0.1:38635/ZhBkkcLBabc=/        ← note: "is listening"
>
> $ dart run tool/vm_service_probe_tmp.dart   (one-off, uses oka's AdbTool)
> devices: [emulator-5554 (device, sdk_gphone64_arm64)]
> scraped: http://127.0.0.1:38635/ZhBkkcLBabc=
> forwarded localhost:65286 -> device:38635
> getVM status: null / 2.0
> VM: name=vm version=3.13.0-282.4.beta on "android_arm64"
> isolates: 1
> PROBE_OK
> ```
>
> The scrape/forward/getVM probe ran through oka's own `AdbTool` — the H2
> device layer is proven against a real device, not just fakes. The
> announcement wording differs from the historical one (newer Flutter:
> `The Dart VM service is listening on` vs `Dart VM Service listening on`);
> `parseVmServiceUri` now matches both (case-insensitive, optional `is`)
> with a regression test using the exact emulator line.
>
> **3. Attach probe — `flutter attach --machine` against the oka-built APK
> (live).** Attach discovers the service URI on its own and reaches
> `app.started`:
>
> ```
> {"event":"daemon.connected","params":{"version":"0.6.1",...}}
> Waiting for a connection from Flutter on sdk gphone64 arm64...
> {"event":"app.start","params":{...,"launchMode":"attach","mode":"debug"}}
> {"event":"app.debugPort","params":{"port":65462,
>     "wsUri":"ws://127.0.0.1:65462/XZgHLBJKpIA=/ws",...}}
> {"event":"app.progress","params":{"progressId":"devFS.update",
>     "message":"Syncing files to device sdk gphone64 arm64...",...}}
> {"event":"app.started","params":{...}}
> ```
>
> **4. `flutter run --machine --use-application-binary <apk>` probe.** Runs
> end-to-end with **zero Gradle invocations** (`grep -ci gradle` on the full
> daemon transcript: 0): `Installing .oka_cache/build/debug/app-debug.apk...`
> → launch → `app.debugPort` → `app.started`. Gradle-free, but it *re-
> installs* the APK itself (duplicating oka's device layer and risking a
> drift against the recorded session manifest).
>
> **5. Decision (H3 integration point): `flutter attach --machine`.**
> oka owns build → install → launch (H2 device layer); attach consumes the
> *running* app without re-installing, reports a usable `wsUri` via
> `app.debugPort`, and never touches Gradle. `run --use-application-binary`
> is recorded as the Gradle-free fallback but duplicates install/launch —
> rejected as the primary path.
>
> **6. Emulator provisioning note (what a human runs once).** Licenses in
> `~/.oka/android-sdk/licenses/` were already accepted; `sdkmanager
> "emulator"` worked non-interactively (slow CDN, ~30 min). The system
> image download via `sdkmanager` was pathologically slow (~10 MB/min), so
> it was fetched directly (12-way parallel curl of
> `https://dl.google.com/android/repository/sys-img/google_apis/arm64-v8a-34_r14.zip`,
> unzipped into `system-images/android-34/google_apis/arm64-v8a/`). The
> reproducible one-time human path is simply:
>
> ```
> sdkmanager "emulator" "system-images;android-34;google_apis;arm64-v8a"
> avdmanager create avd -n h0test -k "system-images;android-34;google_apis;arm64-v8a" -d pixel_5
> emulator -avd h0test -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -no-snapshot
> ```
>
> (Small-disk machines: the pixel_5 profile defaults to a 6 GiB data
> partition; qcow2 keeps the on-disk image small but the free-space check
> still demands the full virtual size.)

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

**Test exit/evidence (H2, 2026-09-07):** delivered via the ADR-0015 device
target + the new H2 adb layer. `adb_tool.dart` (oka_android) owns command
construction, parsers (`parseAdbDevices`, `parseVmServiceUri` — now
matching both Flutter announcement spellings, see the H0 finding —,
`parseForwardPort`) and failure classification (`classifyAdbFailure`:
unauthorized / no-device / device-offline / signing-mismatch /
install-failed / adb-missing); `AdbTool` executes with an injectable path
+ process runner; `AwaitVmServiceStep` / `ForwardVmServiceStep` compose the
scrape + forward into the validated step chain (artifacts `vm_service_uri`,
`vm_service_local_port`). Tests: `test/adr0011_adb_tool_test.dart`
(24 tests: argv construction, fixture parsing incl. the newer
`The Dart VM service is listening on` line, failure table, scripted fake
adb for devices/install/forward/logcat, bounded `awaitVmServiceUri`, step
chain validation). **Live emulator e2e evidence** (headless AVD, API 34
arm64): `oka run device` install → launch → pid alive → no failure
signatures, then oka's `AdbTool` scraped the VM service URI, forwarded
`tcp:0`, and called `getVM` (`PROBE_OK` — full transcript in the H0
evidence block above). Install/launch/logcat-scan step tests predate H2
(`test/adr0015_device_target_test.dart`, scripted fakes).

**Exit:** `oka dev --build --install --launch` (no session yet) works
end-to-end on emulator; evidence recorded.

## H3 — `oka dev` v1: daemon session (machine protocol)

**Goal:** working hot reload for humans and agents.

- [x] `packages/oka_android/lib/src/dev/daemon_adapter.dart`: spawn
      `<sdk>/bin/flutter attach --machine -d <id>` (integration point per H0
      decision; binary from the session manifest's recorded SDK path, never
      PATH); speak the daemon JSON protocol on stdio: send `app.restart`
      (hot reload = `fullRestart: false`, hot restart = `fullRestart: true`,
      both with the `appId` announced by `app.start`), `app.stop`,
      `app.detach`, `daemon.shutdown`; receive events (`app.start`,
      `app.debugPort`, `app.started`, `app.progress`,
      `app.reloadRecommended`, errors). Feature-detect: ignore unknown
      fields/events (protocol is not semver'd); log at `-v` only.
- [x] Replace the stub in `lib/src/cli/dev_command.dart`:
      - default (TTY): oka-rendered progress + `r` (reload), `R` (restart),
        `q` (quit), `d` (detach); **no flutter_tools TUI passthrough** —
        oka renders.
      - `--json`: one structured event per line on stdout (machine stream,
        `pipeline_events.dart`-style envelope) for agents; control lines on
        stdin (`reload`/`restart`/`stop`/`detach`/`quit`) — the one
        explicit interactive surface, never a build path.
      - refuse profile/release (enforced via
        `RunSessionRequest.buildMode='debug'`); refuse on H1 manifest
        mismatch; `-d <id>` device selection with zero/multiple-device
        errors over `AdbTool.devices()` / `AdbDevice.ready`, failures
        mapped through `classifyAdbFailure`.
- [x] Map daemon errors → oka diagnostics: reload failures and
      `app.reloadRecommended` events produce oka-branded messages (an agent
      must be able to act from the message alone).

**Tests:** daemon adapter against a scripted fake (stdio fixture: request/
response JSON lines) — no device needed for the protocol layer; emulator e2e
for the full loop.

**Exit:** on an emulator: edit Dart → `r` reloads; `oka dev --json` +
programmatic reload works headless (the agent-usable acceptance test);
evidence recorded.

> ### H3 evidence
> Filled 2026-09-07 (dev machine; headless AVD `h0test`, API 34 arm64,
> fvm Flutter beta 3.47.0-0.4.pre). All live.
>
> **1. Protocol correction (live probe — supersedes one H0 assumption).**
> The H0 probe observed the events but never *sent* commands. Driving the
> raw daemon revealed: **`app.reload` does not exist** in flutter_tools
> 3.47.0-0.4.pre (`command not understood: app.reload`); the app domain
> registers only `restart` / `callServiceExtension` / `stop` / `detach`,
> and every app-domain command **requires the `appId`** announced by
> `app.start`. So: hot reload = `app.restart {appId, fullRestart: false}`;
> hot restart = `app.restart {appId, fullRestart: true}`. The adapter
> implements the live-probed interface and feature-detects the older
> `app.reload` spelling as a fallback (regression test included).
> Second live finding: the spawned attach child inherits the CLI
> environment, where the oka-managed platform-tools dir is not on PATH —
> attach then reports `No supported devices found`. `spawnAttachDaemon`
> now prepends the resolved tool directory to the child's PATH.
>
> **1b. Env note.** Dev machine paths anonymized here (fvm Flutter beta
> at `~/fvm/default`, oka-managed SDK at `~/.oka/android-sdk`); the
> transcripts below quote only device ids, ports, and event payloads.
>
> **2. Live e2e (headless emulator, `oka run device` first, then
> `oka dev --json -d emulator-5554`, agent drives via stdin control
> lines).** Full transcript in `/tmp/oka_dev_e2e.log`; the decisive
> lines:
>
> ```
> 📲 Installing app-debug.apk → ✅ Installed
> 🚀 Starting com.example.example.MainActivity → ✅ Process alive →
> ✅ No failure signatures in device log
> 🔎 Waiting for the Dart VM service announcement (logcat)...
> 🔌 VM service: http://127.0.0.1:43075/2IDAxNy9rWQ=
> ↔️  Forwarded localhost:58484 → device:43075
> {"scope":"dev","event":"session.start",..."device":"emulator-5554"...}
> {"scope":"dev","event":"daemon.daemon.connected","params":{"version":"0.6.1"...}}
> {"scope":"dev","event":"daemon.app.start","params":{"appId":"881fe2c9-…","launchMode":"attach","mode":"debug"...}}
> {"scope":"dev","event":"daemon.app.debugPort","params":{"port":58501,"wsUri":"ws://127.0.0.1:58501/X2PWkZpfNZo=/ws"...}}
> {"scope":"dev","event":"daemon.app.started",...}
> {"scope":"dev","event":"session.ready","params":{"device":"emulator-5554","wsUri":"ws://127.0.0.1:58501/…/ws"}}
> 🔁 Reload…
> {"scope":"dev","event":"daemon.app.progress","params":{..."progressId":"hot.reload","message":"Performing hot reload..."...}}
> {"scope":"dev","event":"daemon.app.progress","params":{..."progressId":"hot.reload","finished":true...}}
> ✅ Reload complete.
> {"scope":"dev","event":"reload.result","params":{"ok":true}}
> 🔁 Hot restart…
> {"scope":"dev","event":"daemon.app.progress","params":{..."progressId":"hot.restart","finished":true...}}
> ✅ Hot restart complete.
> {"scope":"dev","event":"restart.result","params":{"ok":true}}
> {"scope":"dev","event":"daemon.app.stop","params":{"appId":"881fe2c9-…"}}   ← `quit` stops the app
> ```
>
> The agent-usable acceptance test — headless `--json` + programmatic
> reload completing with `ok:true` — passes on the emulator.
>
> **3. Implementation surface (parse-and-delegate, per ADR-0015).**
> `daemon_adapter.dart` (the only file that knows wire details);
> `dev_session.dart` (`selectDevDevice`, `resolveDevToolPath`,
> `prepareDevLaunch` — the DeviceTarget device steps + the H2
> await-VM-service/forward steps composed in one validated `Pipeline` —,
> `DevSession` render/control loop, `DevFlow` outer loop);
> `lib/src/cli/dev_command.dart` stays a flag parser + wiring shim (the
> platform-leakage gate stays green). Refusals: profile/release, manifest
> mismatch, `-d` selection (zero/multiple/unauthorized devices map
> through `classifyAdbFailure`).
>
> **4. Tests (scripted fakes — no real flutter, no device):**
> `test/adr0011_daemon_adapter_test.dart` (12 tests: argv builder; pinned
> event sequence incl. `daemon.connected` 0.6.1 / `app.start` /
> `app.debugPort` wsUri; bare-object + chatter tolerance; unknown
> events/fields preserved; command gating behind `app.start`; single-
> element-array command shape with `appId` + `fullRestart`; error
> responses typed with actionable text; daemon exit fails pending sends;
> live-probed reload/restart/stop/detach/shutdown interface; older-layout
> `app.reload` fallback). `test/adr0011_dev_session_test.dart` (23 tests:
> keyboard/line control tables; device-selection table incl. zero/
> multiple/unauthorized/unknown-id; human + `--json` rendering; headless
> programmatic reload; reload-failure diagnostics; `app.reloadRecommended`
> tip; rebuild routing with and without `--rebuild-on-native`; daemon
> exit; app.start timeout; `DevFlow` rebuild-then-reattach + build-failure
> stop).

## H4 — `--watch`: change classification & automatic dispatch

**Goal:** agents (and lazy humans) get reload-on-save with honest routing.

- [x] File watcher (`watcher` promoted to a direct dependency of
      `oka_android`) over `lib/`, target file, `android/`, `assets/`,
      `oka.yaml`, `pubspec.yaml` — debounced (quiet-period batching; a
      save storm is one dispatch).
- [x] Classify (`watch.dart: classifyChanges`, table-driven): Dart-only →
      daemon hot reload (`app.restart` fullRestart: false); native/res/
      manifest/config/pubspec → **stop suggesting reload**: print
      "requires `oka build apk --debug` + reinstall" with the exact
      command (`fullRebuildMessage`); `--rebuild-on-native` ends the
      session so [DevFlow] does it automatically (build → reinstall →
      relaunch → re-attach).
- [x] `--watch` implies non-TTY-safe operation (no keyboard; `--json`
      compatible) — this is the agent default loop.

**Tests:** classification table tests (fixture trees); debounce tests;
e2e: edit Dart under `--watch --json` → reload event observed.

**Exit:** classification tests green; headless watch loop demonstrated on
emulator.

> ### H4 evidence
> Filled 2026-09-07.
>
> **1. Live headless watch loop on the emulator.** `oka run device`, then
> `oka dev --watch --json -d emulator-5554` (no keyboard), from another
> shell: append a comment to `lib/main.dart` → the watcher classifies and
> the session reloads automatically:
>
> ```
> 👀 Watch: lib/main.dart → Dart (reload)
> {"scope":"dev","event":"daemon.app.progress","params":{..."progressId":"hot.reload","finished":true...}}
> {"scope":"dev","event":"reload.result","params":{"ok":true}}
> ```
>
> Then touch `android/app/src/main/AndroidManifest.xml` → honest
> full-rebuild routing (reload never suggested):
>
> ```
> 👀 Watch: android/app/src/main/AndroidManifest.xml → native/res/config (full rebuild)
> 🧱 This change needs a full rebuild — hot reload is Dart-only (ADR-0011 §5).
>    fix: `oka build apk --debug` then `oka run device` (or re-run `oka dev`)
>    tip: `oka dev --watch --rebuild-on-native` does it automatically
>    (build → reinstall → relaunch → re-attach).
> {"scope":"dev","event":"rebuild.required","params":{"automatic":false}}
> ```
>
> **2. Tests (scripted, no device):** `test/adr0011_watch_test.dart` (17
> tests): classification table over file-event fixtures (Dart under
> `lib/` → reload; non-Dart under `lib/` → bundled-asset rebuild;
> test/tool/bin → ignore; manifest/gradle/kt/java/so/aar/pro, assets,
> oka.yaml, pubspec → rebuild; build/meta/dot files → ignore; absolute +
> Windows path normalization; strongest action wins in mixed batches);
> quiet-period debounce (save storm → one batch; separated events stay
> separate; trailing batch flushes); classification → command routing;
> `computeDevWatchPaths` fixture-tree coverage (missing dirs skipped,
> target covered by its root, external target watched); one real-watcher
> smoke test (edit a Dart file → debounced hot-reload batch, generous
> timeout for macOS FSEvents latency).

## H5 — Hot restart semantics & polish

**Goal:** restart behaves correctly and docs are true.

- [x] `app.restart` mapping — hot restart = `app.restart {appId,
      fullRestart: true}` (live-probed; there is no `_flutter.hotRestart`
      RPC): a full non-incremental kernel compile + app restart under
      flutter_tools semantics. State-loss messaging matches what actually
      happens: the TTY help and `--json` usage text say "R hot restart
      (state loss)", the docs say the counter/state resets (see the Dev
      loop section in [build_and_config.md](build_and_config.md)).
- [x] Update user-facing docs (`build_and_config.md` → Dev loop section,
      `quick_recipes.md`, README) — docs link to behavior, never paraphrase.
      The three device-flow surfaces are documented as one story: `oka run
      device` (= `oka launch`) is the one-shot install+launch+logscan
      smoke test with **no session**; `oka dev` adds build-parity check +
      VM-service reachability + the attach session.
- [x] `oka doctor`: hot-reload readiness checks (`devLoopDoctorChecks` in
      oka_android; the command formats the lines — parse-and-delegate):
      newest built APK carries a debug session manifest (schema 1), the
      recorded-SDK flutter binary exists, adb resolves and a device is
      ready. Manifest/binary failures are blocking (doctor summary fails);
      a missing device is advisory (⚠️) since phones are often
      intentionally unplugged.

**Tests:** restart e2e; doctor checks unit-tested.

**Exit:** PHASE_CHECKLIST entry for ADR-0010 moved to Done with evidence.

> ### H5 evidence
> Filled 2026-09-07.
>
> **1. Hot restart e2e (live, headless emulator):** see the H3 transcript
> above — `🔁 Hot restart…` → `progressId: hot.restart` finished →
> `restart.result ok:true`. State loss is inherent (kernel recompile +
> process restart); the messaging says so.
>
> **2. Doctor checks (unit-tested, scripted fakes — no device needed):**
> `test/adr0011_dev_doctor_test.dart` (7 tests): ready fixture (manifest +
> recorded binary + ready device), no-APK / pre-manifest / recorded
> profile-mode / missing-recorded-binary → blocking failures naming the
> fix, no ready device → advisory (not blocking), `checkDevice: false`
> skips the device check. Live run on the dev machine (`oka doctor` in
> `example/`):
>
> ```
> [Dev Loop (ADR-0011)]
>   ✅ dev session manifest: .oka_cache/build/debug/app-debug.apk
>      (target=lib/main.dart, mode=debug, engine f88005a259ba)
>   ✅ session flutter binary: ~/fvm/default/bin/flutter (recorded SDK)
>   ✅ device: emulator-5554 ready for attach
> ```
>
> **3. The ADR-0011 protocol correction is recorded in the H3 evidence
> block** (`app.reload` does not exist in the probed SDK; hot reload /
> hot restart are `app.restart` with `fullRestart` false / true and a
> required `appId`).

## Wiring an editor or agent to the delegation channel

Out-of-process tools (the flutter MCP toolkit's `OkaDevSession` adapter,
editors) must drive reload / restart through the **owning** `oka dev`
session — the only compile-capable channel. A late-attached VM-service
connection cannot compile: `ServiceRegistered` events never replay
already-registered services, so reloads sent directly over the VM wire are
**silent no-ops**. The delegation channel exists for exactly this.

1. **Run the session with the channel on:** `oka dev --control-port <port>`
   (or omit the flag for an ephemeral port).
2. **Discover the session:** read `.oka_cache/dev/session.json` under the
   project while `oka dev` runs. All fields are required; `schema` is `1`
   (readers must reject unknown schema values). The file is deleted on
   session exit — an absent file means no live session. `vm_service_uri`
   is the forwarded, host-reachable endpoint (the same line
   `.oka_cache/dev/vm.uri` carries); `control_port` is the delegation
   channel; `pid` lets you detect a dead owner.
3. **Give the toolkit the VM endpoint for reads** (widgets, screenshots,
   evaluate): pass the toolkit's connection override with the exact URI
   from the file — `connection: {"mode": "uri", "uri":
   "<vm_service_uri>"}` (`mode: 'uri'` + `uri` is the toolkit's safest
   selector; it preserves the tokenized VM path exactly — never use
   `host:port` as `targetId`). URI-shaped `targetId` values are also
   accepted.
4. **Delegate reload/restart/stop through the control port** (raw TCP to
   `127.0.0.1:<control_port>`, JSON lines, **no auth — localhost-only dev
   tool**):

   ```json
   {"id": 1, "method": "reload"}
   ```

   → `{"id": 1, "ok": true, "result": {}}` carries the ACTUAL daemon
   outcome. `restart` answers `"fallback": true` when the attach-mode
   fallback (relaunch + re-attach) triggered. Errors are per-id
   (`{"id": …, "ok": false, "error": "<fix>"}`); malformed JSON and
   unknown methods answer in-band and keep the connection open.
   `status` answers from session metadata (device/target/mode).
5. **Handle EOF by re-reading session.json.** The connection may close on
   fallback / session end; a new session owns a new `vm_service_uri` and a
   new `control_port`.

> ### Delegation-channel evidence (filled 2026-09-08)
>
> `test/adr0011_control_server_test.dart` drives the server over real
> loopback sockets against the scripted-fake DevSession: reload → the real
> daemon outcome; restart with a silent `app.restart` → `fallback: true`
> response then EOF on server close; stop; status (no daemon round-trip);
> malformed JSON / unknown method → per-id error with the connection kept
> open; sequential clients; bounded timeout; port discovered from
> session.json. The session.json schema-rejection + write-on-ready /
> clear-on-exit lifecycle is covered alongside. The CLI surface is
> parse-and-delegate only (`lib/src/cli/dev_command.dart`), so the
> ADR-0015 leakage gate stays green.

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
