# 01 — Hello app: the smallest oka build

One Flutter app, one config file, one command. No Gradle anywhere.

## What you get

- `tool/oka_pipeline.dart` — the **entire** Android build config, typed Dart
- `oka build apk` producing `.oka_cache/build/debug/app-debug.apk`
- `oka run device` installing, launching, and crash-scanning it

## Run it

```bash
# one-time: install the CLI + Android SDK
dart pub global activate oka
oka get android-sdk && oka doctor

# this project
flutter pub get
flutter create . --platforms android   # one-time Flutter scaffold (oka ignores Gradle)
oka build apk --debug                  # → .oka_cache/build/debug/app-debug.apk
oka run device                         # install → launch → failure-signature scan
oka explain                            # see the whole build plan, zero tools run
```

## The whole config

```dart
// tool/oka_pipeline.dart
import 'package:oka_android/oka_android.dart';
import 'package:oka_core/oka_core.dart';

Future<void> main(List<String> args) => okaRun(
      args,
      oka: Oka(
        pipelines: [
          AndroidPipeline(
            config: const AndroidBuild(
              name: 'hello_oka',
              packageName: 'com.example.hello_oka',
              minSdk: '23',
              targetSdk: '34',
              compileSdk: '34',
              versionCode: 1,
              versionName: '1.0.0',
            ),
            steps: [...AndroidPipeline.defaultSteps],
          ),
        ],
        targets: [DeviceTarget()],
      ),
    );
```

That's it. `AndroidPipeline.defaultSteps` is the full no-Gradle chain
(codegen → `flutter assemble` → engine extraction → `aapt2`/`d8` →
zipalign → `apksigner` → validation). Swap the values for yours.

## Next

- [02 dev loop](../02_dev_loop) — hot reload with `oka dev`
- [03 release signing](../03_release_signing) — ship-ready builds
