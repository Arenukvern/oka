# Quick recipes

Copy-paste commands for the common loops. Full context in the
[build & configuration guide](../guides/build_and_config.md).

## One-time setup

```bash
git clone https://github.com/Arenukvern/oka.git && cd oka
just install            # dart pub get
just global             # activate oka globally
oka get android-sdk     # bootstrap SDK into ~/.oka/android-sdk (or use existing)
oka doctor              # verify everything
```

## Build & install loop (three flows, one story)

```bash
cd example && flutter pub get
oka build apk --debug          # → .oka_cache/build/debug/app-debug.apk
                               #    (+ run_session.json flag-parity record)

# Flow A — smoke test (one-shot; no session; `oka launch` = same dispatch):
oka run device                 # install → launch → failure-signature scan

# Flow B — dev session (hot reload / hot restart):
oka dev                        # parity check → install → launch → attach
#   human TTY:  r hot reload · R hot restart (state loss) · q quit · d detach
#   agent:      oka dev --json      (events on stdout; stdin lines
#               reload/restart/stop/detach/quit after `session.ready`)
#   agent loop: oka dev --watch --json   (Dart edits → auto reload;
#               native edits → honest full-rebuild command)
```

Hot reload is Dart-only: native/res/manifest/asset/config changes always
need `oka build apk --debug` + reinstall (ADR-0011 §5) — `--watch` prints
the exact command, `--watch --rebuild-on-native` runs it for you.
Docs: [Dev Loop Station](../guides/build_and_config.md#-dev-loop-station-adr-0011).

## Release

```bash
oka build apk --release
oka build aab --verify-aab      # bundle + bundletool universal-APK verification
```

## Tests & lint

```bash
just test       # dart test
just lint       # dart analyze
```

## Dependency recovery

```bash
oka get dep androidx.window:window:1.3.0        # cache artifact, print yaml snippet
oka clean --full                                # nuke all caches
```
