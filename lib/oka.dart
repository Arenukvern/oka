/// Oka: a declarative, no-Gradle build system for Flutter Android.
///
/// This package is the `oka` CLI and agent surface. It composes the platform
/// packages into one build path that never invokes Gradle:
///
/// | Package | Role |
/// |---|---|
/// | [oka_core] | Contracts: typed build context, `BuildStep`/`Artifact` pipeline, the declarative `Oka` composition root |
/// | [oka_android] | Android pipelines, build steps, direct Android SDK toolchain (`aapt2`, `d8`, `apksigner`) |
/// | oka (this package) | The `oka` CLI (`bin/`), doctor/get commands, version contract |
///
/// {@template oka_cli_usage}
/// Most users only need the CLI — oka reads a typed Dart entrypoint (or the
/// legacy `oka.yaml`) from the project and runs the no-Gradle pipeline:
///
/// ```bash
/// $ oka init                       # scaffold tool/oka_pipeline.dart
/// $ oka build apk --release        # no-Gradle release APK
/// $ oka build aab                  # no-Gradle Android App Bundle
/// $ oka explain                    # print the validated build plan (no tools)
/// ```
/// {@endtemplate}
///
/// ## Composing a pipeline in Dart
///
/// Projects that want full control declare their pipeline in Dart (ADR-0006)
/// and point `oka build` at it via `pipeline.dart_entrypoint`:
///
/// ```dart
/// import 'package:oka_android/oka_android.dart';
/// import 'package:oka_core/oka_core.dart';
///
/// Future<void> main(List<String> args) => okaRun(
///       args,
///       oka: const Oka(
///         pipelines: [
///           AndroidPipeline(
///             config: AndroidBuild(packageName: 'dev.example.app'),
///           ),
///         ],
///       ),
///     );
/// ```
///
/// Hook authors should depend on `oka_android` (which transitively provides
/// `oka_core`), not this CLI package, to keep the host-app dependency surface
/// minimal.
///
/// See also:
///
/// * [okaRun], the runtime that powers project entrypoints.
/// * [AndroidPipeline], the default no-Gradle Android pipeline.
/// * [Oka], the declarative composition root.
library;

export 'package:oka_android/oka_android.dart';
export 'package:oka_core/oka_core.dart';

export 'src/version.dart';
