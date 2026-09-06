/// Oka core contracts (ADR-0006): typed build context, composable pipeline
/// with typed artifacts, and the declarative composition root.
///
/// This barrel is the public API of oka_core and is semver-covered.
library;

export 'src/composition.dart';
export 'src/config/android_build.dart';
export 'src/config/android_config.dart';
export 'src/config/build_context.dart';
export 'src/config/dependency.dart';
export 'src/config/flutter_config.dart';
export 'src/config/manifest_merge_result.dart';
export 'src/config/maven_coordinate.dart';
export 'src/config/oka_config.dart';
export 'src/config/plugin_metadata.dart';
export 'src/oka_run.dart';
export 'src/pipeline/pipeline.dart';
export 'src/pipeline_events.dart';
export 'src/process_runner.dart';
