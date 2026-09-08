import 'package:oka_core/oka_core.dart';

import 'build/dependency_cache.dart';
import 'build/engine_artifacts.dart';
import 'build/host_codegen.dart';
import 'build/plugin_discovery.dart';
import 'build/plugin_packager.dart';
import 'build/toolchain.dart';
import 'pipeline_overrides.dart';

/// Typed accessors for Android build artifacts shared across steps
/// (ADR-0006).
///
/// The extension gives every step compile-time-checked reads/writes over the
/// pipeline store, so no step has to hand-roll string keys:
///
/// ```dart
/// @override
/// Future<StepResult> run(BuildContext ctx, PipelineState state) async {
///   final overrides = state.pipelineOverrides ?? const PipelineOverrides();
///   final abis = state.abis.isEmpty ? const ['arm64-v8a'] : state.abis;
///   // ...
/// }
/// ```

/// Key under which [AndroidPipeline.run] seeds the merged pipeline-level
/// overrides into the runtime scope (ADR-0010): hooks composing explicit
/// step lists get fast-settings applied without threading constructors.
const pipelineOverridesKey = 'pipeline_overrides';

/// Key under which [AndroidPipeline.run] seeds the resolved toolchain
/// (ADR-0013 T1): one shared, printable resolution policy for all steps.
const resolvedToolchainKey = 'resolved_toolchain';

/// The store keys match the ids of the artifact constants in
/// `android_artifacts.dart`.
extension AndroidPipelineState on PipelineState {
  /// Merged pipeline-level overrides (yaml fast-settings + typed Dart
  /// config), seeded by [AndroidPipeline.run]. Steps fall back to this for
  /// values their constructors leave unset.
  PipelineOverrides? get pipelineOverrides =>
      this[pipelineOverridesKey] as PipelineOverrides?;

  set pipelineOverrides(final PipelineOverrides? v) =>
      this[pipelineOverridesKey] = v;

  /// Resolved toolchain (ADR-0013 T1): the ordered, printable resolution
  /// policy injected by [AndroidPipeline.run]. Steps stop calling a
  /// locator god-object and resolve tools through this instead.
  ResolvedToolchain? get resolvedToolchain =>
      this[resolvedToolchainKey] as ResolvedToolchain?;

  set resolvedToolchain(final ResolvedToolchain? v) =>
      this[resolvedToolchainKey] = v;

  /// Resolved ABIs for this build.
  List<String> get abis => _asList('abis');

  set abis(final List<String> v) => this['abis'] = v;

  /// Plugin discovery result.
  PluginDiscoveryResult? get pluginDiscovery =>
      this['plugin_discovery'] as PluginDiscoveryResult?;

  set pluginDiscovery(final PluginDiscoveryResult? v) =>
      this['plugin_discovery'] = v;

  /// Packaged plugin outputs.
  PluginPackagingResult? get packagedPlugins =>
      this['packaged_plugins'] as PluginPackagingResult?;

  set packagedPlugins(final PluginPackagingResult? v) =>
      this['packaged_plugins'] = v;

  /// Registrations feeding GeneratedPluginRegistrant.
  List<PluginRegistration> get registrations =>
      _asList<PluginRegistration>('registrations');

  set registrations(final List<PluginRegistration> v) => this['registrations'] = v;

  /// Directory of generated host sources (MainActivity, registrant, manifest).
  String? get hostDir => this['host_dir'] as String?;

  set hostDir(final String? v) => this['host_dir'] = v;

  /// flutter_assets directory from assemble.
  String? get flutterAssetsDir => this['flutter_assets_dir'] as String?;

  set flutterAssetsDir(final String? v) => this['flutter_assets_dir'] = v;

  /// ABI → libflutter.so path.
  Map<String, String> get libflutterByAbi =>
      _asMap('libflutter_by_abi');

  set libflutterByAbi(final Map<String, String> v) => this['libflutter_by_abi'] = v;

  /// ABI → libapp.so path (release only).
  Map<String, String> get libappByAbi => _asMap('libapp_by_abi');

  set libappByAbi(final Map<String, String> v) => this['libapp_by_abi'] = v;

  /// Resolved AndroidX jars.
  List<ResolvedJar> get androidxJars => _asList<ResolvedJar>('androidx_jars');

  set androidxJars(final List<ResolvedJar> v) => this['androidx_jars'] = v;

  /// Flutter embedding classes jar.
  String? get embeddingJar => this['embedding_jar'] as String?;

  set embeddingJar(final String? v) => this['embedding_jar'] = v;

  /// Extra runtime jars injected by user config / hooks
  /// (`pipeline.extra_deps` in oka.yaml or Dart composition).
  List<String> get extraRuntimeJars => _asList<String>('extra_runtime_jars');

  set extraRuntimeJars(final List<String> v) => this['extra_runtime_jars'] = v;

  /// Native libs from processed AARs (Maven + local): abi → .so paths.
  Map<String, List<String>> get aarNativeLibsByAbi =>
      _asMapList('aar_native_libs_by_abi');

  set aarNativeLibsByAbi(final Map<String, List<String>> v) =>
      this['aar_native_libs_by_abi'] = v;

  /// Resource dirs extracted from AARs (values XML trees for aapt2).
  List<String> get aarResDirs => _asList<String>('aar_res_dirs');

  set aarResDirs(final List<String> v) => this['aar_res_dirs'] = v;

  /// Produced dex files (classes.dex, classes2.dex, …).
  List<String> get dexFiles => _asList<String>('dex_files');

  set dexFiles(final List<String> v) => this['dex_files'] = v;

  /// Final APK path.
  String? get apkPath => this['apk_path'] as String?;

  set apkPath(final String? v) => this['apk_path'] = v;

  // -- private cast helpers ------------------------------------------------

  List<T> _asList<T>(final String key) =>
      (this[key] as List<Object?>?)?.cast<T>() ?? List<T>.empty();

  Map<String, String> _asMap(final String key) =>
      (this[key] as Map<Object?, Object?>?)?.cast<String, String>() ??
      const <String, String>{};

  Map<String, List<String>> _asMapList(final String key) =>
      (this[key] as Map<Object?, Object?>?)?.cast<String, List<String>>() ??
      const <String, List<String>>{};
}

/// Engine artifacts helper shared by engine-related steps.
Future<EngineArtifacts> engineArtifacts(
  final BuildContext ctx,
  final ResolvedToolchain toolchain,
) async {
  final sdk = ctx.flutterSdkPath.isNotEmpty
      ? ctx.flutterSdkPath
      : await toolchain.findFlutterSdk();
  return EngineArtifacts(sdk, verbose: ctx.verbose);
}
