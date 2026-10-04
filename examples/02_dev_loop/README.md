# 02 — Dev loop: hot reload without Gradle

Same app as [01](../01_hello_app); the new thing is the session:
`oka dev` builds, installs, launches, and attaches — then Dart edits reload
in place. State is preserved on hot reload (`r`), lost on hot restart (`R`).

## Run it

```bash
flutter pub get
flutter create . --platforms android     # one-time scaffold
oka build apk --debug                    # once — oka records run_session.json
oka dev                                  # attach: r reload · R restart · q quit · d detach
```

Try it: with the session running, change the string in `lib/main.dart`,
press `r`, watch the app update without losing the counter.

## The agent loop

```bash
oka dev --watch --json
```

- Dart edits reload automatically; structured events print on stdout.
- Native/res/manifest edits print the **honest full-rebuild command** — hot
  reload is Dart-only, never a silent dex push.
- `--watch --rebuild-on-native` runs that command for you: rebuild →
  reinstall → relaunch → re-attach.

Add `--dart-define` or `--target` changes to a live session and `oka dev`
refuses with the differing fields — flag parity is enforced against the
recorded build ([ADR-0011](../../docs/decisions/0011-hot-reload-run-loop.mdx)).

## Notes

- Debug (JIT) only: profile/release sessions refuse loudly.
- The counter survives `r` (hot reload) and resets on `R` (hot restart) —
  a quick way to feel the difference.

## Next

- [03 release signing](../03_release_signing) — make it store-ready
