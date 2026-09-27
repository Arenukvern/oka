# oka_rustore

RuStore publish target for [oka](https://github.com/Arenukvern/oka) — the
no-Gradle Flutter Android build system. `RuStorePublishTarget` composes a
RuStore AAB upload plan onto **any oka Android AAB build**, as one typed
value in your existing `Oka(...)` composition root. No CLI changes, no
Gradle, no oka.yaml.

**Dry-run by default.** Until you set `dryRun: false` *and* provide a
project credential/upload adapter, the target compiles to a plan step that
prints exactly what a real run would do — endpoint, track, and artifact —
and issues zero HTTP. A real run without a project-provided credential
adapter is refused with an actionable message; oka ships no vendored
credential/upload code for RuStore.

## 30-second quickstart

```dart
import 'package:oka/oka.dart';

Future<void> main(final List<String> args) => okaRun(
      args,
      oka: const Oka(
        pipelines: [
          AndroidPipeline(
            config: AndroidBuild(
              name: 'my_app',
              packageName: 'com.example.my_app',
            ),
            steps: AndroidPipeline.defaultSteps,
          ),
        ],
        targets: [
          // Dry-run is the default: a plan, no HTTP, no credentials.
          RuStorePublishTarget(),
        ],
      ),
    );
```

Run it:

```bash
oka build aab --release   # produce the artifact
oka run publish-rustore   # print the upload plan
```

## Publishing for real

Provide the credential/upload adapter your project owns (tier-2 credential —
a file path or environment reference, never an inlined secret), then flip
`dryRun: false` on the target. See the
[publishing guide](https://docs.page/arenukvern/oka/guides/publishing) for
the walkthrough, and `oka explain --targets` to inspect the composed plan
without touching the network.

## Links

- [oka](https://github.com/Arenukvern/oka) — one code for every platform
  build
- [Publishing guide](https://docs.page/arenukvern/oka/guides/publishing)
- [Changelog](CHANGELOG.md)
