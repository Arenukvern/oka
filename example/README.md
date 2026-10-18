# example — the full oka reference app

This is oka's reference Flutter app: every build feature composed in one
project-owned file, [`tool/oka_pipeline.dart`](tool/oka_pipeline.dart) —
Android pipeline, manifest/deeplink overrides, extra deps and assets,
adaptive icons, store publish targets, web shell, and the verification
targets. It is the canonical copy-paste source the docs link to.

Prefer small steps? Climb the [examples ladder](../examples) instead —
six minimal projects, smallest first.

## Run it

```bash
flutter pub get
oka explain                # the validated build plan — zero tools invoked
oka build apk --debug      # → .oka_cache/build/debug/app-debug.apk
oka run device             # install → launch → failure-signature scan
oka explain --targets      # every declared target (device, verify, publish…)
```

Release and stores:

```bash
oka build apk --release          # AOT + R8 + signed, provenance included
oka run verify                   # prove the release actually starts
oka run publish-play             # dry-run plan — flip dryRun: false when ready
```

Requires the `oka` CLI (`dart pub global activate oka`) and an Android SDK
(`oka get android-sdk` bootstraps one into `~/.oka/android-sdk`).
