/// Oka Android platform package (ADR-0006).
///
/// Public API for hook authors: pipelines, steps, typed config/spec values,
/// artifact keys, and the Android toolchain. Depends only on `oka_core` plus
/// lightweight packages — no CLI/AI surface.
library oka_android;

export 'package:oka_core/oka_core.dart';

// Artifact keys + typed state accessors.
export 'src/android_artifacts.dart';
export 'src/auto_resolve.dart';
export 'src/android_state.dart';

// Platform pipeline.
export 'src/android_pipeline.dart';

// Build machinery.
export 'src/build/aab_layout.dart';
export 'src/build_cache.dart';
export 'src/build/aapt2_commands.dart';
export 'src/build/android_builder.dart';
export 'src/build/android_sdk_installer.dart';
export 'src/build/apk_layout.dart';
export 'src/build/bundletool.dart';
export 'src/build/cargo_apk_manifest.dart';
export 'src/build/dependency_cache.dart';
export 'src/maven_resolver.dart';
export 'src/build/dependency_suggest.dart';
export 'src/build/engine_artifacts.dart';
export 'src/build/flutter_android_builder.dart';
export 'src/build/flutter_apk_builder.dart';
export 'src/build/flutter_assemble.dart';
export 'src/build/flutter_asset_bundler.dart';
export 'src/build/gradle_dep_parser.dart';
export 'src/build/host_codegen.dart';
export 'src/build/java_environment.dart';
export 'src/build/launcher_icon.dart';
export 'src/build/plugin_discovery.dart';
export 'src/build/plugin_packager.dart';
export 'src/build/sdk_locator.dart';
export 'src/build/version_manager.dart';

// Pipeline.
export 'src/manifest_spec.dart';
export 'src/signing_config.dart';
export 'src/post_build_lint.dart';
export 'src/pipeline/default_pipeline.dart';
export 'src/pipeline/steps/asset_steps.dart';
export 'src/pipeline/steps/flutter_steps.dart';
export 'src/pipeline/steps/host_steps.dart';
export 'src/pipeline/steps/tool_steps.dart';
export 'src/pipeline/toolchain.dart';
