/// The kernel pipeline as a library for live patching (ADR-0031/0032):
/// resolve the pinned toolchain once, then compile per-unit deltas through
/// the fastest available path (AOT exe, JIT dart fallback).
///
/// Resolution is convention-first — everything derives from the running
/// dart unless overridden — so a patch composition root is a Dart file
/// with no config file:
///
/// ```dart
/// final toolchain = await resolvePipelineToolchain(
///     okaDartKernelRoot: '../..');
/// final receipt = await runLivePatch(
///   patch, root: appRoot,
///   compile: pipelineDeltaCompiler(toolchain),
///   onEvent: (e) => print(e.why),
/// );
/// ```
library;

import 'dart:io';

import 'package:oka_update/oka_update.dart';

String _join(String a, [String? b, String? c]) {
  var r = a;
  for (final s in [b, c]) {
    if (s != null) r = '$r/$s';
  }
  return r;
}

/// Everything the delta compiler needs, resolved.
final class PipelineToolchain {
  const PipelineToolchain({
    required this.checkout,
    required this.packagesConfig,
    required this.sdkSummary,
    required this.sdkHash,
    required this.dartBin,
    required this.kernelRoot,
    this.appPackagesConfig,
    this.exe,
  });

  /// Pinned SDK checkout the kernel stack is compiled from.
  final String checkout;

  /// Merged kernel-stack package config (kernel/vm/front_end).
  final String packagesConfig;

  /// Platform dill the delta is compiled against.
  final String sdkSummary;

  /// The checkout's sdk_hash (baked into the AOT exe; passed as -D to JIT).
  final String sdkHash;

  /// The dart binary deltas are JIT-compiled with when no exe is present.
  final String dartBin;

  /// The oka_dart_kernel package root (tool/ home) the JIT path runs in.
  final String kernelRoot;

  /// The TARGET APP's package config. When the app runs under one
  /// (`--packages=`), the delta MUST be compiled with it so the delta's
  /// library importUris match the loaded libraries (URI coherence).
  final String? appPackagesConfig;

  /// AOT pipeline exe when built/found; null = JIT dart path.
  final String? exe;

  Map<String, Object?> toJson() => {
        'checkout': checkout,
        'sdkHash': sdkHash,
        'packagesConfig': packagesConfig,
        'sdkSummary': sdkSummary,
        'aot': exe != null,
      };
}

/// Default checkout location this machine provisions:
/// `~/xs/dart-sdks/sdk-<major.minor.patch>` (see skills/oka-kernel
/// references/toolchain.md). OKA_SDK_CHECKOUT overrides.
String defaultSdkCheckout(String dartVersion) {
  final env = Platform.environment['OKA_SDK_CHECKOUT'];
  if (env != null && env.isNotEmpty) return env;
  final home = Platform.environment['HOME'] ?? '.';
  return _join(home, 'xs/dart-sdks', 'sdk-$dartVersion');
}

/// Resolves the toolchain with convention-first defaults:
/// - dart binary: [dartBin] ?? the running executable
/// - checkout: [checkout] ?? OKA_SDK_CHECKOUT ?? `~/xs/dart-sdks/sdk-<ver>`
/// - packages config: built (and cached under ~/.oka/cache) via
///   `tool/pipeline_packages_config.sh`
/// - AOT exe: built once into the same cache when [buildExe]; JIT fallback
///   if the build fails
///
/// [okaDartKernelRoot] is the oka_dart_kernel package root (home of
/// tool/pipeline_packages_config.sh); defaults to the current directory
/// when that script exists there.
Future<PipelineToolchain> resolvePipelineToolchain({
  String? checkout,
  String? dartBin,
  Directory? workDir,
  String? okaDartKernelRoot,
  String? appPackagesConfig,
  bool buildExe = true,
}) async {
  final bin = dartBin ?? Platform.resolvedExecutable;
  final versionOut = await Process.run(bin, ['--version']);
  // 3.13 prints the version on stdout (older SDKs: stderr).
  final ver = RegExp(r'([0-9]+)\.([0-9]+)\.([0-9]+)')
      .firstMatch('${versionOut.stdout}${versionOut.stderr}')
      ?[0];
  if (ver == null) {
    throw StateError('cannot determine dart version from $bin');
  }
  final langVersion = ver.split('.').take(2).join('.');

  final co = checkout ?? defaultSdkCheckout(ver);
  if (!Directory(co).existsSync()) {
    throw StateError('SDK checkout missing: $co — provision it (see '
        'skills/oka-kernel references/toolchain.md) or pass checkout');
  }
  final hashOut = await Process.run('git', ['rev-parse', '--short=10', 'HEAD'],
      workingDirectory: co);
  final sdkHash = (hashOut.stdout as String).trim();

  final rawRoot = okaDartKernelRoot ??
      (File('tool/pipeline_packages_config.sh').existsSync() ? '.' : null);
  if (rawRoot == null) {
    throw StateError('cannot locate oka_dart_kernel/tool — pass '
        'okaDartKernelRoot');
  }
  // Process.run's workingDirectory must be absolute.
  final kernelRoot = Directory(rawRoot).absolute.path;

  final home = Platform.environment['HOME'] ?? '.';
  final cache = (workDir ??
          Directory(_join(home, '.oka/cache/oka-pipeline', sdkHash)))
      .absolute
      .path;
  Directory(cache).createSync(recursive: true);
  final packages = _join(cache, 'pipeline_package_config.json');
  if (!File(packages).existsSync()) {
    final proc = await Process.run('bash', [
      'tool/pipeline_packages_config.sh',
      co,
      langVersion,
      cache,
    ], workingDirectory: kernelRoot);
    if (proc.exitCode != 0 || !File(packages).existsSync()) {
      throw StateError('pipeline package config failed '
          '(exit ${proc.exitCode}, exists=${File(packages).existsSync()}): '
          '${proc.stderr} ${proc.stdout}');
    }
  }
  final summary = _join(File(bin).parent.parent.path,
      'lib/_internal/vm_platform_strong.dill');
  if (!File(summary).existsSync()) {
    throw StateError('platform dill missing: $summary');
  }

  String? exe;
  if (buildExe) {
    final exePath = _join(cache, 'pipeline.exe');
    if (File(exePath).existsSync()) {
      exe = exePath;
    } else {
      final build = await Process.run('bash', [
        'tool/build_pipeline_exe.sh',
        co,
        langVersion,
        exePath,
      ], workingDirectory: kernelRoot);
      if (build.exitCode == 0 && File(exePath).existsSync()) {
        exe = exePath;
      }
    }
  }
  final appConfig =
      appPackagesConfig == null ? null : File(appPackagesConfig).absolute.path;
  return PipelineToolchain(
    checkout: co,
    packagesConfig: packages,
    sdkSummary: summary,
    sdkHash: sdkHash,
    dartBin: bin,
    kernelRoot: kernelRoot,
    appPackagesConfig: appConfig,
    exe: exe,
  );
}

/// The injected [UnitDeltaCompiler] for [LivePatchSession]: AOT exe when the
/// toolchain has one, JIT `dart tool/gate_pipeline.dart --delta` otherwise.
UnitDeltaCompiler pipelineDeltaCompiler(PipelineToolchain toolchain) =>
    (request) async {
      final out = '${Directory.systemTemp.createTempSync('oka-delta').path}'
          '/${request.unit}.delta.dill';
      final ProcessResult proc;
      final env = {
        'DART_SDK_SUMMARY': toolchain.sdkSummary,
        // URI coherence: when the app runs under a package config, the
        // delta must be compiled under the same one.
        'DART_PACKAGES_CONFIG': ?toolchain.appPackagesConfig,
      };
      final exe = toolchain.exe;
      if (exe != null) {
        proc = await Process.run(exe, [
          '--delta',
          request.patchedFiles.first,
          out,
        ], environment: env);
      } else {
        proc = await Process.run(toolchain.dartBin, [
          '-Dsdk_hash=${toolchain.sdkHash}',
          '--packages=${toolchain.packagesConfig}',
          'tool/gate_pipeline.dart',
          '--delta',
          request.patchedFiles.first,
          out,
        ], workingDirectory: toolchain.kernelRoot, environment: env);
      }
      if (proc.exitCode != 0) {
        throw StateError('unit delta compile failed: ${proc.stderr}');
      }
      return DeltaArtifact(path: out, bytes: File(out).lengthSync());
    };
