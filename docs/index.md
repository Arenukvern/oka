# Oka — no-Gradle Flutter Android builds

Oka is a Dart CLI that replaces Gradle for Flutter Android builds. It runs
`flutter assemble` and invokes Android SDK tools (`aapt2`, `javac`, `d8`,
`zipalign`, `apksigner`) directly — no Gradle daemon, no AGP, no 30-second
configuration tax on every build.

## Choose your path

| Audience | Start here |
| --- | --- |
| Build an app now | [Quick recipes](/start_here/quick_recipes) |
| Publish to Google Play / AppGallery | [Publishing guide](/guides/publishing) |
| Understand the project | [Why this repo matters](/start_here/why_this_repo_matters) |
| Configure a build | [Build & configuration guide](/guides/build_and_config) |
| Contribute / change architecture | [Docs map](/start_here/docs_map) |

## Highlights

- **No Gradle, ever** — the default path never falls back to
  `flutter build apk` (enforced by tests).
- **Plugin packaging** — Flutter plugin sources, Maven/AAR dependencies,
  natives and resources, `GeneratedPluginRegistrant`.
- **Fast settings** — extra deps, extra assets, deeplinks, adaptive vector
  launcher icons: all declarative in `oka.yaml`.
- **AAB support** — hand-assembled App Bundles with optional bundletool
  verification.
- **Dependency recovery** — runtime missing-class crashes map back to Maven
  artifacts automatically.

```bash
dart pub global activate --source path .   # or: just global
oka get android-sdk && oka doctor
cd example && oka build apk
```

## Status

Experimental but actively used. See the
[phase checklist](/PHASE_CHECKLIST) for what is proven by tests, and the
[roadmap](/start_here/roadmap) for what's next.
