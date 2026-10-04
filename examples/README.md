# Examples ladder — learn oka by building

Six runnable projects, smallest first. Each has a five-minute README and a
`tool/oka_pipeline.dart` you can copy into your own app verbatim.

| Step | You learn | Prereqs |
|---|---|---|
| [01 hello app](01_hello_app) | The smallest oka build: one Dart config file, one command | Dart, Flutter, Android SDK (`oka get android-sdk`) |
| [02 dev loop](02_dev_loop) | Hot reload / hot restart with `oka dev` | 01 |
| [03 release signing](03_release_signing) | Release builds: signing, R8, provenance, `oka run verify` | 01 |
| [04 stores & accounts](04_stores_accounts) | Play + AppGallery + RuStore targets, two Play accounts, white-label brands | 03 |
| [05 web stores](05_web_stores) | Typed web shell, GitHub Pages + itch.io deploy | Dart, Flutter |
| [06 live patch](06_live_patch) | Patch a running app via the air channel (`oka ship`) | the oka repo checkout |

The one rule across all of them: **the build config is Dart you own.** No
plugin DSLs, no hidden defaults — everything below is copy-paste and
type-checked.

Running from this repo? The full reference app lives in
[`example/`](../example) — every feature composed in one file.
