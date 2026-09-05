/// Example: composing a custom build pipeline with the oka Dart API
/// (ADR-0006 declarative composition).
///
/// The default `oka build apk` command already assembles a full pipeline from
/// `oka.yaml`. This entrypoint shows the **Dart composition** layer:
/// a typed, immutable [Oka] root with the default Android steps plus two
/// custom steps.
///
/// Run it (from the repo root):
///
/// ```bash
/// dart run example/bin/custom_pipeline.dart
/// ```
///
/// Precedence reminder: built-in defaults < `oka.yaml` < this script.
library;

import 'dart:io';

import 'package:oka_android/oka_android.dart';
import 'package:oka_core/oka_core.dart';

Future<void> main(List<String> args) => okaRun(
  args,
  oka: Oka(
    pipelines: [
      AndroidPipeline(
        overrides: PipelineOverrides(
          extraDeps: ['com.squareup.okhttp3:okhttp:4.12.0'],
        ),
        // Default no-Gradle steps plus two custom ones. To reorder or
        // replace, spread `AndroidPipeline.defaultSteps` and edit the list.
        steps: [
          EnsureAndroidSdkStep(),
          ResolveAbisStep(),
          PluginPackagingStep(),
          HostCodegenStep(),
          FlutterAssembleStep(),
          EngineExtractionStep(),
          ReleaseAotStep(),
          DependencyResolveStep(),
          // ↓ Custom step A: generate a build-info asset before packaging.
          BuildInfoStampStep(),
          CompileAndDexStep(),
          PackageAndSignStep(),
          // Custom step B: observe the packaged artifact.
          PrintChecksumStep(),
          ValidateLayoutStep(),
        ],
      ),
    ],
  ),
);

/// Custom step example A: writes a build-stamp file into flutter_assets,
/// demonstrating typed artifact reads/writes.
class BuildInfoStampStep extends BuildStep {
  @override
  String get name => 'build-info-stamp';

  @override
  Set<Artifact<Object>> get requires => {flutterAssetsDir};

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    final out = File('${ctx.buildDir}/assemble/flutter_assets/build_info.txt');
    await out.parent.create(recursive: true);
    await out.writeAsString(
      'built=${DateTime.now().toIso8601String()}\n'
      'abis=${state.abis.join(',')}\n',
    );
    print('🧩 build stamp written: ${out.path}');
    return StepResult.success();
  }
}

/// Custom step example B: observes the packaged artifact without modifying it.
class PrintChecksumStep extends BuildStep {
  @override
  String get name => 'print-checksum';

  @override
  Set<Artifact<Object>> get requires => {apkPath};

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    final apk = state.apkPath;
    if (apk == null) return StepResult.failure('no apk staged');
    final bytes = await File(apk).length();
    print('🔐 APK: $apk (${(bytes / 1024 / 1024).toStringAsFixed(1)} MB)');
    return StepResult.success();
  }
}
