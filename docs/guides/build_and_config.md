---
title: Build & configuration guide
---

# Build & configuration guide

How to run, build, and extend oka. Why-rationale lives in the
[design FAQ](design_faq.md); settled decisions in
[`docs/decisions/`](../decisions/index.md).

## 🏠 Setup Hub

**Q: How do I start a new project (oka init)?**
```bash
oka init               # full-Dart config: scaffolds tool/oka_pipeline.dart
                       # (typed AndroidBuild/FlutterBuild) — no oka.yaml
oka init --yaml        # legacy YAML-first scaffold (with AI gradle conversion
                       # when android/app/build.gradle exists)
oka init --from-yaml   # converts an existing oka.yaml 1:1 into the typed
                       # Dart entrypoint (ADR-0010)
```
`oka build` discovers `tool/oka_pipeline.dart` by convention — no YAML key
needed. Non-interactive sessions (CI/agents) skip overwrite prompts; pass
`--force` to overwrite.

**Q: How do I depend on oka packages before their first pub.dev release?**
`oka_android` declares a hosted `oka_core` constraint, so until both are
published, host projects resolve them locally:
```yaml
dependency_overrides:
  oka_android:
    path: /path/to/oka/packages/oka_android
  oka_core:
    path: /path/to/oka/packages/oka_core
```
Publish order (release train, see `.github/workflows/pub_publish.yml`):
`oka_core` → `oka_android` → `oka`. Drop the overrides once published.

**Q: How do I install oka and its Android SDK?**
```bash
just install          # dart pub get
just global           # activate globally (clears snapshot cache)
oka get android-sdk   # bootstrap SDK into ~/.oka/android-sdk
oka doctor            # verify everything
```

**Q: How do I start a new project?**
```bash
oka init   # generates oka.yaml from pubspec.yaml (or converts an existing
           # android/app/build.gradle with AI assist)
```
The scaffold includes a **commented** `pipeline.dart_entrypoint` example
(ADR-0006's declarative Dart hook) and a pointer to the full composition
example (`example/tool/oka_pipeline.dart` in the oka repository). Uncomment
when you want to own the pipeline in Dart; otherwise the YAML fast-settings
path builds unchanged.

**Q: How do I catch dependency/version resolution problems before building?**
```bash
oka explain --deps            # resolve the plugin dependency plan against
                              # the local ~/.oka maven cache (offline-safe)
oka explain --deps --network  # full resolution incl. downloads + POM
                              # transitives; exit 1 on hard failures
```
Composes the plan from gradle-parsed plugin deps (post conditional-dedup,
ADR-0007) + `pipeline.extra_deps` + the flutter-embedding set — the same
collector and resolver the build uses, so plan and packaging cannot disagree.
Cache-only misses print `⚠️ not in local maven cache`; with `--network` a
resolution failure (404, unresolvable POM) prints `❌` and fails the dry-run.
See [ADR-0008](../decisions/0008-dependency-plan-dry-run.md).

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
just test    # dart test
just lint    # dart analyze
```

## 🎛️ Full-Dart project config (ADR-0010)

**Q: Can I drop oka.yaml and configure everything in Dart?**
Yes. Create `tool/oka_pipeline.dart` (discovered by convention — no YAML key
needed) and move the whole config there, strictly typed:

```dart
// tool/oka_pipeline.dart
Future<void> main(List<String> args) => okaRun(
  args,
  oka: const Oka(
    pipelines: [
      AndroidPipeline(
        config: AndroidBuild(          // was android: + top-level name:
          name: 'example',
          packageName: 'com.example.example',
          minSdk: '23', targetSdk: '36', compileSdk: '36',
          versionCode: 51, versionName: '3.22.0',
          abis: ['arm64-v8a'],
          javaVersion: 17,
        ),
        flutterConfig: FlutterBuild(   // was flutter:
          entrypoint: 'lib/main_prod.dart',
          treeShakeIcons: true,
        ),
        overrides: PipelineOverrides(  // was pipeline: + android.icon/manifest
          resourceConfigs: ['en', 'ru'],
          manifest: ManifestSpec(permissions: [...]),
        ),
        steps: [...AndroidPipeline.defaultSteps],
      ),
    ],
  ),
);
```

- Field mapping: `android:` → `AndroidBuild`, `flutter:` → `FlutterBuild`,
  `pipeline:` + `android.icon/manifest/res_dirs` → `PipelineOverrides`,
  top-level `name:` → `AndroidBuild.name`.
- Precedence: defaults < `oka.yaml` (if kept) < typed Dart config < CLI args.
- **Migrating an existing project** (e.g. last_answer):
  ```bash
  oka init --from-yaml   # converts oka.yaml 1:1 into tool/oka_pipeline.dart
  oka explain            # verify the plan
  oka build apk && oka compare old.apk .oka_cache/build/debug/app-debug.apk
  ```
- Proven byte-equivalent: same-hook A/B (yaml vs `AndroidBuild`) produced
  identical badging/manifest/arsc/dex (ADR-0010 evidence). Full example:
  `example/tool/oka_pipeline.dart`.

## 🪝 Dart entrypoint hooks (ADR-0006)

**Q: How do I customize the pipeline without editing oka?**

Declare a Dart entrypoint in `oka.yaml` (the **only** extensibility key —
YAML growth is frozen; everything else is Dart):

```yaml
pipeline:
  dart_entrypoint: tool/oka_pipeline.dart
```

`oka build` then delegates to `dart run tool/oka_pipeline.dart` with the same
args (`--release/--aab/--abi/--target/--dart-define…`). The hook composes a
declarative, typed `Oka` root — no mutable step surgery, no stringly maps:

```dart
// tool/oka_pipeline.dart
import 'package:oka_android/oka_android.dart';
import 'package:oka_core/oka_core.dart';

Future<void> main(List<String> args) => okaRun(
  args,
  oka: Oka(
    pipelines: [
      AndroidPipeline(
        overrides: PipelineOverrides().copyWith(
          resourceConfigs: ['en', 'ru'],
        ),
        steps: [...AndroidPipeline.defaultSteps, MyStep()],
      ),
    ],
  ),
);
```

- `okaRun` handles arg parsing, `oka.yaml` merge, SDK/cache dirs.
- Steps declare `requires`/`provides` artifact sets (`Artifact<T>` typed
  keys); the runner **validates the whole chain before any tool runs** and
  fails naming the missing producer.
- Config is overridden exclusively with `copyWith` on typed values
  (`PipelineOverrides`, `ManifestSpec`, `SigningConfig`).
- Reusable logic ships as ordinary Dart packages; depend on `oka_android`
  (light deps) in the host app, not the `oka` CLI.

Projects without `dart_entrypoint` keep the AOT fast path unchanged.
See `example/tool/oka_pipeline.dart` for a working hook.

**Q: How do I customize the Android manifest?**

The manifest is a typed `ManifestSpec` rendered by `host-codegen` — no XML
patching, no per-attribute YAML fields:

```yaml
android:
  manifest:
    permissions: [android.permission.INTERNET, android.permission.CAMERA]
    cleartext_traffic: true
    flutter_deeplinking: true
    application_attributes: {android:icon: "@mipmap/ic_launcher"}
    activity_attributes: {android:theme: "@style/LaunchTheme"}
    application_meta_data:
      - name: io.flutter.embedding.android.NormalTheme
        resource: "@style/NormalTheme"
    deeplinks:
      - {scheme: https, host: example.com}   # autoVerify
      - {scheme: myapp}                       # scheme-only custom scheme
```

Hooks override it wholesale via `ManifestSpec.copyWith`. The user `res/`
tree (themes, splash, mipmaps) merges via `android.res_dirs`.

## ⚡ Incremental build cache

`plugin-packaging`, `flutter-assemble`, `release-aot` and `compile-and-dex`
are fingerprint-gated (content-hash for sources/manifests/res; size+mtime for
jars). Unchanged inputs skip Maven resolution, kotlinc and d8 entirely —
production-app repeat builds drop from minutes to ~25s. Fingerprints live in
`.oka_cache/build/<mode>/step_cache.json`; `oka clean` or deleting the build
dir resets. Any input change (sources, deps, defines, tool versions, manifest)
forces a full re-run of that step only.

**Q: How do I re-run a single pipeline step against the existing cache?**
```bash
oka debug step compile-and-dex              # run one step (plus its upstream
                                            # prefix, cache-hit cheap) with
                                            # verbose output
oka debug step --list                       # discover available steps
oka debug step plugin-packaging --project /path/to/app
```
Uses the same context building as `okaRun` (oka.yaml + dart-defines +
`.oka_cache` layout), so the probe sees exactly what a build sees. A single
step cannot run alone — its upstream artifact providers run first; the
incremental step cache keeps the prefix fast on a warm cache.

## 🔐 Signing & versioning (G2)

```yaml
android:
  version_code: 51          # injected via aapt2 --version-code
  version_name: 3.22.0      # injected via aapt2 --version-name
  resource_configs: [en, ru]  # aapt2 -c qualifier filter
  exclude_plugins: [integration_test]  # test-only plugins
  signing:
    keystore: keys/release.jks
    alias: upload
    store_password_env: OKA_STORE_PASS   # secrets via env, never yaml
    key_password_env: OKA_KEY_PASS
```

Signing fallback chain: explicit config → `oka.yaml android.signing` →
`android/key.properties` (Gradle-compatible) → debug keystore (dev only;
release builds warn loudly).

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

## 🚢 Release Station

**Q: How do I cut a release?**
Merge conventional commits to `main`; release-please opens a Release PR that
bumps `VERSION` + `CHANGELOG.md`. The sync workflow derives pubspec/plugin
versions automatically. Merge → tag → pub.dev publish (automated). Full
runbook: [contribution guide](../contributing/contribution_guide.md).

**Q: How do I verify version consistency locally?**
```bash
just check-contracts   # VERSION == pubspec == plugin manifests; docs drift; changelog hygiene
just sync-version      # fix drift from VERSION
```

**Q: How do I prove a refactor produced a byte-equivalent artifact?**
```bash
oka compare old.apk new.apk          # exit 1 on differences
oka compare old.aab new.aab --quiet  # differences don't fail (CI-friendly)
oka compare a.apk b.apk --skip-badging   # zip entries only
```
Diffs `aapt2 dump badging` (package, versionCode/Name, permissions,
intent-filter/launchable metadata) and the zip entry lists (entries only in
one artifact + common entries whose content changed, via crc32). This is the
formal byte-equivalence gate for pipeline refactors (ADR-0007) — a claim is a
command, not a PR description.

## 🧪 Source-contract tests note

**Q: What are "source contract" tests?**
Tests that assert implementation details by reading source files (e.g.
`test/layout_validation_fail_test.dart`). When moving code between files,
update the paths in these tests — they encode invariants (no Gradle fallback,
layout validation must fail loudly), not just locations.
