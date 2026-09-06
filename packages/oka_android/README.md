# oka_android

Android platform pipelines for [oka](https://github.com/Arenukvern/oka) — the
no-Gradle build system for Flutter Android: `flutter assemble` + direct SDK
tools (aapt2, javac/kotlinc, d8, apksigner). Ships the default APK/AAB
pipelines, plugin packaging with transitive Maven resolution, post-build
lint, and the typed config/composition values (`AndroidPipeline`,
`PipelineOverrides`, `ManifestSpec`, `AndroidBuild`).

Depends only on [oka_core](https://pub.dev/packages/oka_core) plus
lightweight packages — no CLI/AI surface (ADR-0006).

See the [docs](https://docs.page/arenukvern/oka) and the
[design decisions](https://github.com/Arenukvern/oka/tree/main/docs/decisions).
