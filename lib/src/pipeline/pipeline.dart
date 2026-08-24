import 'dart:io';

import 'package:path/path.dart' as p;

import '../build/dependency_cache.dart';
import '../build/engine_artifacts.dart';
import '../build/host_codegen.dart';
import '../build/plugin_discovery.dart';
import '../build/plugin_packager.dart';
import '../build/sdk_locator.dart';
import '../config/build_context.dart';

/// Mutable state shared across pipeline steps.
///
/// Steps read inputs from [BuildContext] (immutable config) and communicate
/// intermediate artifacts through this store. Keys are typed accessors below;
/// steps may add custom keys for downstream custom steps.
class PipelineState {
  final Map<String, Object?> _values = {};

  Object? operator [](String key) => _values[key];
  void operator []=(String key, Object? value) => _values[key] = value;

  // Typed accessors for well-known keys.

  /// Resolved ABIs for this build.
  List<String> get abis => _values['abis'] as List<String>? ?? const [];

  set abis(List<String> v) => _values['abis'] = v;

  /// Plugin discovery result.
  PluginDiscoveryResult? get pluginDiscovery =>
      _values['plugin_discovery'] as PluginDiscoveryResult?;

  set pluginDiscovery(PluginDiscoveryResult? v) =>
      _values['plugin_discovery'] = v;

  /// Packaged plugin outputs.
  PluginPackagingResult? get packagedPlugins =>
      _values['packaged_plugins'] as PluginPackagingResult?;

  set packagedPlugins(PluginPackagingResult? v) =>
      _values['packaged_plugins'] = v;

  /// Registrations feeding GeneratedPluginRegistrant.
  List<PluginRegistration> get registrations =>
      _values['registrations'] as List<PluginRegistration>? ?? const [];

  set registrations(List<PluginRegistration> v) => _values['registrations'] = v;

  /// Directory of generated host sources (MainActivity, registrant, manifest).
  String? get hostDir => _values['host_dir'] as String?;

  set hostDir(String? v) => _values['host_dir'] = v;

  /// flutter_assets directory from assemble.
  String? get flutterAssetsDir => _values['flutter_assets_dir'] as String?;

  set flutterAssetsDir(String? v) => _values['flutter_assets_dir'] = v;

  /// ABI → libflutter.so path.
  Map<String, String> get libflutterByAbi =>
      (_values['libflutter_by_abi'] as Map<String, String>?) ?? const {};

  set libflutterByAbi(Map<String, String> v) =>
      _values['libflutter_by_abi'] = v;

  /// ABI → libapp.so path (release only).
  Map<String, String> get libappByAbi =>
      (_values['libapp_by_abi'] as Map<String, String>?) ?? const {};

  set libappByAbi(Map<String, String> v) => _values['libapp_by_abi'] = v;

  /// Resolved AndroidX jars.
  List<ResolvedJar> get androidxJars =>
      _values['androidx_jars'] as List<ResolvedJar>? ?? const [];

  set androidxJars(List<ResolvedJar> v) => _values['androidx_jars'] = v;

  /// Flutter embedding classes jar.
  String? get embeddingJar => _values['embedding_jar'] as String?;

  set embeddingJar(String? v) => _values['embedding_jar'] = v;

  /// Extra runtime jars injected by user config / hooks
  /// (`pipeline.extra_deps` in oka.yaml or Dart composition).
  List<String> get extraRuntimeJars =>
      _values['extra_runtime_jars'] as List<String>? ?? const [];

  set extraRuntimeJars(List<String> v) => _values['extra_runtime_jars'] = v;

  /// Produced dex files (classes.dex, classes2.dex, …).
  List<String> get dexFiles =>
      _values['dex_files'] as List<String>? ?? const [];

  set dexFiles(List<String> v) => _values['dex_files'] = v;

  /// Final APK path.
  String? get apkPath => _values['apk_path'] as String?;

  set apkPath(String? v) => _values['apk_path'] = v;
}

/// Result of a single pipeline step.
class StepResult {
  final bool ok;
  final String? error;
  final Map<String, Object?> data;

  const StepResult({required this.ok, this.error, this.data = const {}});

  factory StepResult.success([Map<String, Object?> data = const {}]) =>
      StepResult(ok: true, data: data);

  factory StepResult.failure(String error) =>
      StepResult(ok: false, error: error);
}

/// A composable unit of the build pipeline.
///
/// Implement this to add, replace, or wrap stages. Steps must be idempotent
/// enough to re-run after a failure (oka cleans its own intermediates).
abstract class BuildStep {
  /// Unique step name, used in logs and YAML overrides (`pipeline.steps`).
  String get name;

  Future<StepResult> run(BuildContext ctx, PipelineState state);
}

/// Runs a list of steps in order, stopping at the first failure.
class Pipeline {
  final List<BuildStep> steps;
  final bool verbose;

  Pipeline(this.steps, {this.verbose = false});

  Future<StepResult> run(BuildContext ctx) async {
    final state = PipelineState();
    for (final step in steps) {
      if (verbose) print('▶ step: ${step.name}');
      try {
        final result = await step.run(ctx, state);
        if (!result.ok) {
          return StepResult.failure(
            'step "${step.name}" failed: ${result.error}',
          );
        }
      } on Exception catch (e) {
        return StepResult.failure('step "${step.name}" threw: $e');
      }
    }
    return StepResult.success({'apk_path': state.apkPath});
  }
}

/// Shared helpers used by several steps.
Future<void> copyDirectory(Directory source, Directory dest) async {
  await dest.create(recursive: true);
  await for (final e in source.list(recursive: true, followLinks: false)) {
    final rel = p.relative(e.path, from: source.path);
    final out = p.join(dest.path, rel);
    if (e is Directory) {
      await Directory(out).create(recursive: true);
    } else if (e is File) {
      await File(out).parent.create(recursive: true);
      await e.copy(out);
    }
  }
}

/// Engine artifacts helper shared by engine-related steps.
Future<EngineArtifacts> engineArtifacts(
  BuildContext ctx,
  SdkLocator locator,
) async {
  final sdk = ctx.flutterSdkPath.isNotEmpty
      ? ctx.flutterSdkPath
      : await locator.findFlutterSdk();
  return EngineArtifacts(sdk, verbose: ctx.verbose);
}
