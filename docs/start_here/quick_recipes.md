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

## Build & install loop

```bash
cd example && flutter pub get
oka build apk                                   # → .oka_cache/build/debug/app-debug.apk
adb install -r .oka_cache/build/debug/app-debug.apk
adb shell am start -n com.example.example/.MainActivity
adb logcat -d -b crash | grep com.example       # crash check
```

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
