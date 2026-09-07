/// Canonical Android artifact keys (ADR-0006).
///
/// Steps declare these in [BuildStep.requires]/[BuildStep.provides]; the
/// runner validates the chain at composition time. Ids match the
/// `PipelineState` store keys used by the typed accessors in
/// `android_state.dart`.
library;

import 'dart:io';

import 'package:oka_core/oka_core.dart';

import 'build/host_codegen.dart' show PluginRegistration;

/// Resolved ABIs for the build (provided by `resolve-abis`).
const abis = Artifact<List<String>>('abis');

/// Plugin discovery result (provided by `plugin-packaging`).
const pluginDiscovery = Artifact<Object>('plugin_discovery');

/// Packaged plugin outputs — sources, jars, natives (provided by
/// `plugin-packaging`).
const packagedPlugins = Artifact<Object>('packaged_plugins');

/// Plugin registrations feeding GeneratedPluginRegistrant.
const registrations = Artifact<List<PluginRegistration>>('registrations');

/// Generated host sources dir — MainActivity, registrant, manifest
/// (provided by `host-codegen`).
const hostDir = Artifact<String>('host_dir');

/// flutter_assets directory from `flutter assemble`.
const flutterAssetsDir = Artifact<String>('flutter_assets_dir');

/// ABI → libflutter.so paths (provided by `engine-extraction`).
const libflutterByAbi = Artifact<Map<String, String>>('libflutter_by_abi');

/// ABI → libapp.so paths, release AOT (provided by `release-aot`).
const libappByAbi = Artifact<Map<String, String>>('libapp_by_abi');

/// Flutter embedding classes jar (provided by `engine-extraction`).
const embeddingJar = Artifact<String>('embedding_jar');

/// Resolved AndroidX / runtime jars (provided by `dependency-resolve` and
/// merged by `extra-deps`).
const androidxJars = Artifact<Object>('androidx_jars');

/// Extra runtime jars injected by user config / hooks.
const extraRuntimeJars = Artifact<List<String>>('extra_runtime_jars');

/// Native libs from processed AARs: abi → .so paths.
const aarNativeLibsByAbi = Artifact<Object>('aar_native_libs_by_abi');

/// Resource dirs extracted from AARs (values XML trees for aapt2).
const aarResDirs = Artifact<List<String>>('aar_res_dirs');

/// Produced dex files (provided by `compile-and-dex` /
/// `compile-proto-and-dex`).
const dexFiles = Artifact<List<String>>('dex_files');

/// Final APK path (provided by `package-and-sign` / `package-and-sign-aab`).
const apkPath = Artifact<String>('apk_path');

/// Session manifest path recorded by `record-run-session` (ADR-0011 H1).
const runSessionPath = Artifact<String>('run_session_path');

/// VM service URI scraped from device log (provided by `await-vm-service`).
const vmServiceUri = Artifact<String>('vm_service_uri');

/// Local host port from `adb forward tcp:0` (provided by
/// `forward-vm-service`).
const vmServiceLocalPort = Artifact<int>('vm_service_local_port');

/// Staged APK layout directory (pre-zip).
const apkStagingDir = Artifact<Directory>('apk_staging_dir');
