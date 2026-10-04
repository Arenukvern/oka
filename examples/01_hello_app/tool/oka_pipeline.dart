/// Example 01 — the whole Android build config, one typed Dart file.
///
/// `oka build` discovers this file by convention. `okaRun` handles arg
/// parsing, SDK/cache dirs, and running the pipeline.
library;

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
    // `oka run device` (alias `oka launch`): install → launch →
    // failure-signature scan.
    targets: [DeviceTarget()],
  ),
);
