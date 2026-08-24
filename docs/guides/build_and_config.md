---
title: Build & configuration guide
---

# Build & configuration guide

How to run, build, and extend oka. Why-rationale lives in the
[design FAQ](design_faq.md); settled decisions in
[`docs/decisions/`](../decisions/index.md).

## 🏠 Setup Hub

**Q: How do I install oka and its Android SDK?**
```bash
make install          # dart pub get
make global           # activate globally (clears snapshot cache)
oka get android-sdk   # bootstrap SDK into ~/.oka/android-sdk
oka doctor            # verify everything
```

**Q: How do I build the example app?**
```bash
cd example && flutter pub get && oka build apk
# output: .oka_cache/build/debug/app-debug.apk
```

**Q: How do I build an App Bundle (AAB) for Play Store?**
```bash
oka build aab            # or: oka build release aab
# output: .oka_cache/build/<mode>/aab/app-<mode>.aab
```
Same `oka.yaml` config, plugins, extra_deps, icons and deeplinks as APK builds.
Resources link with `aapt2 --proto-format`; the bundle signs with jarsigner v1
(debug keystore by default — supply your upload key for store releases).

**Q: An .aab can't be installed directly — how do I verify it?**
An App Bundle is an upload format; Play/bundletool generate the installable
split APKs. Verify locally (bundletool exercises the same parsing path as Play):
```bash
oka get bundletool          # one-time download into ~/.oka/tools
oka build aab --verify-aab  # runs bundletool build-apks --mode=universal
adb install -r .oka_cache/build/<mode>/universal/app-universal.apk
adb shell am start -n com.example.example/.MainActivity
```

**Q: How do I install & launch on a device?**
```bash
adb install -r example/.oka_cache/build/debug/app-debug.apk
adb shell am start -n com.example.example/.MainActivity
adb logcat -d -b crash | grep com.example   # check for crashes
```

**Q: How do I run tests?**
```bash
make test    # dart test
make lint    # dart analyze
```

## 🔧 Build Pipeline Station (ADR 0002)

**Q: What are the pipeline steps and where do they live?**

Default order (composed in `lib/src/pipeline/default_pipeline.dart`):

| # | Step | File |
|---|------|------|
| 1 | `ensure-android-sdk` | `steps/host_steps.dart` |
| 2 | `resolve-abis` | `steps/host_steps.dart` |
| 3 | `plugin-packaging` | `steps/host_steps.dart` |
| 4 | `host-codegen` (manifest, MainActivity, icon) | `steps/host_steps.dart` |
| 5 | `flutter-assemble` | `steps/flutter_steps.dart` |
| 6 | `engine-extraction` | `steps/flutter_steps.dart` |
| 7 | `release-aot` | `steps/flutter_steps.dart` |
| 8 | `dependency-resolve` | `steps/flutter_steps.dart` |
| 9 | `extra-deps` | `default_pipeline.dart` |
| 10 | `compile-and-dex` | `steps/tool_steps.dart` |
| 11 | `extra-assets` | `steps/asset_steps.dart` |
| 12 | `package-and-sign` | `steps/tool_steps.dart` |
| 13 | `validate-layout` | `steps/tool_steps.dart` |

Shared tool logic (aapt2/javac/d8/zipalign/apksigner invocations) lives in
`lib/src/pipeline/toolchain.dart`.

**Q: How do I add a custom step?**
Implement `BuildStep` from `lib/src/pipeline/pipeline.dart`:
```dart
class MyStep implements BuildStep {
  @override
  String get name => 'my-step';
  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    // read config from ctx, share artifacts via state
    return StepResult.success();
  }
}
```
Compose it into a `Pipeline([...])` and call `pipeline.run(ctx)`.

**Q: How does data flow between steps?**
Via `PipelineState` — a typed blackboard (`state.abis`, `state.flutterAssetsDir`,
`state.dexFiles`, `state.apkPath`, …). Steps read upstream outputs and write
their own. Custom keys use the `[]` operator.

**Q: What is the config precedence?**
Built-in defaults < `oka.yaml` `pipeline:` section < Dart composition
(a user-built `Pipeline` always wins).

## 📦 Dependencies Station

**Q: How do I add an extra runtime dependency without editing oka?**
In the project's `oka.yaml`:
```yaml
pipeline:
  extra_deps:
    - "com.squareup.okhttp3:okhttp:4.12.0"
```
It resolves from Google Maven / Maven Central into `~/.oka/cache/maven` and is
dexed into the APK.

**Q: A build fails with `NoClassDefFoundError: Lfoo/Bar;` — what now?**
Oka auto-suggests the Maven artifact on build failure. To resolve manually:
```bash
oka get dep androidx.window:window:1.3.0
```
This caches the artifact and prints the exact `oka.yaml` snippet.
Mapping table: `lib/src/build/dependency_suggest.dart`
(`kKnownClassArtifacts`) — add new entries there when you discover gaps.

**Q: Where is the default AndroidX embedding dependency set?**
`flutterEmbeddingAndroidXDeps()` in `lib/src/build/dependency_cache.dart`.
Edit only when adding artifacts needed by *every* Flutter host; project-specific
ones belong in `pipeline.extra_deps`.

## 🎨 Assets & Icon Station

**Q: How do I bundle extra assets beyond pubspec?**
```yaml
pipeline:
  extra_assets:
    - from: build/generated-config.json   # file or dir, project-relative
      to: generated-config.json           # flutter_assets-relative destination
```
Runs after flutter-assemble; sources must exist or the build fails.

**Q: How do I package a local .aar file?**
```yaml
pipeline:
  local_aars:
    - libs/my-native-lib.aar   # project-relative path
```
Oka extracts classes.jar (dex input), `jni/<abi>/*.so` natives (staged to
`lib/<abi>/`), and `res/**` XML (merged into aapt2 compile). Resource-only
AARs (no classes.jar) are supported.

**Q: What happens to res/ and jni/ inside Maven AARs?**
They're extracted automatically. When oka resolves an AAR from Maven it also
unpacks `jni/<abi>/*.so` and `res/**/*.xml` into the cache (`payload/` dir
next to classes.jar) and merges them into the build — no config needed.
Implementation: `extractAarPayload` in `lib/src/build/dependency_cache.dart`.

**Q: How do I set the launcher icon?**
```yaml
android:
  icon:
    background_color: "#E8F5E9"         # or @color/ref
    vector: assets/icon/foreground.xml  # VectorDrawable XML (108dp viewport)
    monochrome: assets/icon/mono.xml    # optional, Android 13+ themed icons
```
Vector-first: no PNG tooling needed; works on API 26+. Implementation:
`lib/src/build/launcher_icon.dart`.

**Q: How do I add deeplinks?**
```yaml
pipeline:
  deeplinks:
    - scheme: https
      host: oka.example.com
      pathPrefix: /app
```
Generates `autoVerify` intent-filters on MainActivity. Test with:
```bash
adb shell am start -a android.intent.action.VIEW \
  -d "https://oka.example.com/app/settings" com.example.example
```

## 🩺 Troubleshooting Station

**Q: Install fails with `-124: resources.arsc ... uncompressed and aligned`?**
The packager must store `resources.arsc` uncompressed (`zipStagingToApk` in
`lib/src/build/apk_layout.dart`) and zipalign with `-p 4`. Both are wired;
if regressed, device installs on Android 11+ fail.

**Q: App crashes at launch with missing classes but tests pass?**
Runtime link errors don't surface at compile time. Reproduce with adb, read
`adb logcat -d -b crash`, then follow the dependency-recovery flow above.

**Q: Device shows `unauthorized` in adb?**
Accept the USB debugging dialog on the phone (unlock first). If stale:
Developer options → Revoke USB debugging authorizations → replug.

**Q: kotlinc fails with JDK version errors?**
Kotlin 2.1 rejects JDK 25+; `kotlinJavaEnvironment()` in
`lib/src/pipeline/toolchain.dart` probes for JDK 17–21 automatically.

## 🧪 Source-contract tests note

**Q: What are "source contract" tests?**
Tests that assert implementation details by reading source files (e.g.
`test/layout_validation_fail_test.dart`). When moving code between files,
update the paths in these tests — they encode invariants (no Gradle fallback,
layout validation must fail loudly), not just locations.
