/// Example 02 — same no-Gradle pipeline as 01; the lesson is the session:
///   oka build apk --debug && oka dev
/// See this project's README for the human and agent surfaces.
library;

import 'package:oka_android/oka_android.dart';
import 'package:oka_core/oka_core.dart';

Future<void> main(List<String> args) => okaRun(
  args,
  oka: Oka(
    pipelines: [
      AndroidPipeline(
        config: const AndroidBuild(
          name: 'dev_loop_oka',
          packageName: 'com.example.dev_loop_oka',
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
