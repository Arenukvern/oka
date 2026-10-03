/// Live-patch e2e driver (ADR-0031/0032/0034): turns a declarative
/// live_patch.json into a full cross-platform apply through the
/// `oka_update` session API, using oka's own pipeline as the delta
/// compiler (`tool/gate_pipeline.dart --delta`).
///
/// Config via env:
///   LIVE_SPEC          path to the live patch spec (JSON)
///   LIVE_ROOT          app root the spec's relative paths resolve against
///   LIVE_RECEIPT       optional output path for the receipt JSON
/// Delta compiler (same shape the G3 gates use):
///   LIVE_DELTA_DART    dart SDK to compile the delta with
///   LIVE_DELTA_PACKAGES  merged package_config for the compiler
///   LIVE_DELTA_CWD     working dir of oka_dart_kernel (gate_pipeline home)
///   LIVE_SDK_HASH      -Dsdk_hash for the compiler (when required)
///   DART_SDK_SUMMARY   platform dill the delta is compiled against
///   DART_PACKAGES_CONFIG app package config (import URIs match)
///   OKA_TARGET         vm | flutter | web (pipeline target)
///
/// The delta is compiled from the FIRST patch's file — the unit lane
/// semantics (the unit's library is the reload root, pruned to the unit).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_update/oka_update.dart';

Future<void> main() async {
  final env = Platform.environment;
  final specPath = env['LIVE_SPEC'];
  final root = env['LIVE_ROOT'];
  if (specPath == null || root == null) {
    stderr.writeln('live_e2e: LIVE_SPEC and LIVE_ROOT are required');
    exitCode = 64;
    return;
  }

  final spec = await LivePatchSpec.load(specPath);
  final session = LivePatchSession(
    spec: spec,
    root: root,
    compile: _pipelineDeltaCompiler,
    onEvent: (e) => stdout.writeln('live: ${e.why}'),
  );

  final LivePatchReceipt receipt;
  try {
    receipt = await session.run();
  } finally {
    // The session restores nothing; gates/traps own file state.
  }
  stdout.writeln(receipt.describe());
  final receiptPath = env['LIVE_RECEIPT'];
  if (receiptPath != null) {
    await File(receiptPath)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(receipt));
  }
  // Explicit exit: lingering wire handles must not hold the process.
  exit(receipt.ok ? 0 : 1);
}

/// Compiles the unit delta. Fast path: a prebuilt AOT pipeline exe
/// (LIVE_PIPELINE_EXE — `dart compile exe --define=sdk_hash=...`; identical
/// output, ~7-11x faster than the JIT dart run). Fallback: the plain dart
/// run of `tool/gate_pipeline.dart --delta`.
Future<DeltaArtifact> _pipelineDeltaCompiler(DeltaRequest request) async {
  final env = Platform.environment;
  final unitFile = request.patchedFiles.first;
  // The delta must live at a path the TARGET's VM can open. LIVE_DELTA_DIR
  // lets a gate place it inside the app root when the app runs in a
  // container that shares that path; otherwise a host temp dir.
  final tmpDir = env['LIVE_DELTA_DIR'];
  final tmp = tmpDir == null
      ? await Directory.systemTemp.createTemp('oka-live-delta')
      : Directory(tmpDir)..createSync(recursive: true);
  final out = '${tmp.path}/${request.unit}.delta.dill';

  final exe = env['LIVE_PIPELINE_EXE'];
  if (exe != null && File(exe).existsSync()) {
    final proc = await Process.run(exe, ['--delta', unitFile, out],
        environment: {
          'DART_SDK_SUMMARY': env['DART_SDK_SUMMARY'] ?? '',
          'DART_PACKAGES_CONFIG': env['DART_PACKAGES_CONFIG'] ?? '',
          'OKA_TARGET': env['OKA_TARGET'] ?? 'vm',
        });
    if (proc.exitCode != 0) {
      stderr.writeln('[delta] ${proc.stderr}');
      throw StateError('unit delta compile failed (${proc.exitCode})');
    }
    return DeltaArtifact(path: out, bytes: File(out).lengthSync());
  }

  final dartBin = env['LIVE_DELTA_DART'] ?? Platform.resolvedExecutable;
  final deltaPackages = env['LIVE_DELTA_PACKAGES'];
  final cwd = env['LIVE_DELTA_CWD'] ?? Directory.current.path;
  final sdkHash = env['LIVE_SDK_HASH'];
  if (deltaPackages == null) {
    throw StateError('LIVE_DELTA_PACKAGES is required for the unit lane');
  }

  final proc = await Process.run(
    dartBin,
    [
      if (sdkHash != null && sdkHash.isNotEmpty) '-Dsdk_hash=$sdkHash',
      '--packages=$deltaPackages',
      'tool/gate_pipeline.dart',
      '--delta',
      unitFile,
      out,
    ],
    workingDirectory: cwd,
    environment: {
      'DART_SDK_SUMMARY': env['DART_SDK_SUMMARY'] ?? '',
      'DART_PACKAGES_CONFIG': env['DART_PACKAGES_CONFIG'] ?? '',
      'OKA_TARGET': env['OKA_TARGET'] ?? 'vm',
    },
  );
  if (proc.exitCode != 0) {
    stderr.writeln('[delta] ${proc.stderr}');
    throw StateError('unit delta compile failed (${proc.exitCode})');
  }
  final artifact = DeltaArtifact(path: out, bytes: File(out).lengthSync());
  return artifact;
}
