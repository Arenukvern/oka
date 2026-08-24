/// Example: composing a custom build pipeline with the oka Dart API (ADR 0002).
///
/// The default `oka build apk` command already assembles a full pipeline from
/// `oka.yaml`. This file shows the **full Dart composition** layer for cases
/// where you need to reorder, replace, or wrap steps.
///
/// Run it:
///
/// ```bash
/// cd example
/// dart run bin/custom_pipeline.dart
/// ```
///
/// Precedence reminder: built-in defaults < oka.yaml < this kind of script.
library;

import 'dart:io';

import 'package:oka/src/build/dependency_cache.dart';
import 'package:oka/src/build/flutter_assemble.dart';
import 'package:oka/src/build/plugin_discovery.dart';
import 'package:oka/src/build/sdk_locator.dart';
import 'package:oka/src/config/build_context.dart';
import 'package:oka/src/pipeline/default_pipeline.dart';
import 'package:oka/src/pipeline/pipeline.dart';
import 'package:oka/src/pipeline/steps/flutter_steps.dart';
import 'package:oka/src/pipeline/steps/host_steps.dart';
import 'package:oka/src/pipeline/steps/tool_steps.dart';

Future<void> main() async {
  // --- 1. Standard context (same shape `oka build apk` builds internally). ---
  final projectPath = Directory.current.path;
  final ctx = BuildContext.fromJson({
    'project_path': projectPath,
    'build_dir': '$projectPath/.oka_cache/build/debug',
    'mode': 'debug',
    'config': await _loadOkaConfig(projectPath),
    'cache_dir': '$projectPath/.oka_cache/cache',
    'temp_dir': '$projectPath/.oka_cache/tmp',
    'flutter_sdk_path': '',
    'android_sdk_path':
        Platform.environment['ANDROID_SDK_ROOT'] ??
        Platform.environment['OKA_ANDROID_SDK'] ??
        '',
    'build_timestamp': DateTime.now().millisecondsSinceEpoch,
    'verbose': Platform.environment['OKA_VERBOSE'] == '1',
    'flavor': '',
    'target_abi': '',
    'build_aab': false,
  });

  final sdkLocator = SdkLocator();
  final cache = DependencyCache(verbose: ctx.verbose);

  // --- 2. Compose your pipeline. -------------------------------------------
  //
  // This example wraps the DEFAULT steps and inserts two custom ones:
  //   * a pre-package hook that stamps build time into an asset
  //   * a post-package hook that prints APK size info
  final pipeline = Pipeline([
    // Default steps, in default order (subset shown; see
    // defaultApkPipeline() for the canonical list).
    EnsureAndroidSdkStep(sdkLocator),
    ResolveAbisStep(),
    PluginPackagingStep(
      sdkLocator: sdkLocator,
      pluginDiscovery: PluginDiscovery(verbose: false),
      dependencyCache: cache,
    ),
    HostCodegenStep(),
    FlutterAssembleStep(
      sdkLocator: sdkLocator,
      assembler: FlutterAssembler(verbose: false),
    ),
    EngineExtractionStep(sdkLocator),
    DependencyResolveStep(cache),

    // ↓ Your custom steps can go anywhere in the list.

    // Custom step A: generate a build-info asset before packaging.
    _BuildInfoStampStep(),

    CompileAndDexStep(sdkLocator),
    PackageAndSignStep(sdkLocator),

    // Custom step B: observe the packaged artifact without modifying it.
    _PrintChecksumStep(),
    ValidateLayoutStep(),
  ], verbose: ctx.verbose);

  // --- 3. Run. ---------------------------------------------------------------
  final result = await pipeline.run(ctx);
  if (!result.ok) {
    stderr.writeln('❌ ${result.error}');
    exit(1);
  }
  stdout.writeln('✅ Custom pipeline APK: ${result.data['apk_path']}');
}

Future<Map<String, dynamic>> _loadOkaConfig(String projectPath) async {
  // Minimal config map; a real script could parse oka.yaml via loadYaml.
  return {
    'name': 'example',
    'android': {
      'compile_sdk': '34',
      'min_sdk': '21',
      'target_sdk': '34',
      'java_version': '11',
      'package_name': 'com.example.example',
      'abis': ['arm64-v8a'],
    },
    'flutter': {'entrypoint': 'lib/main.dart'},
  };
}

/// Custom step example A: writes a build-stamp file into flutter_assets,
/// demonstrating how steps share state and produce artifacts.
class _BuildInfoStampStep implements BuildStep {
  @override
  String get name => 'build-info-stamp';

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
class _PrintChecksumStep implements BuildStep {
  @override
  String get name => 'print-checksum';

  @override
  Future<StepResult> run(BuildContext ctx, PipelineState state) async {
    final apk = state.apkPath;
    if (apk == null) return StepResult.failure('no apk staged');
    final bytes = await File(apk).length();
    print('🔐 APK: $apk (${(bytes / 1024 / 1024).toStringAsFixed(1)} MB)');
    return StepResult.success();
  }
}
