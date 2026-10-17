/// The app's own frontend as a delta compiler (ADR-0035 §2e / ADR-0036):
/// kernel deltas only parse in a VM whose frontend produced them, so
/// every flutter-app target compiles through
/// `frontend_server_aot.dart.snapshot` + the flutter patched SDK.
library;

import 'dart:io';

import 'package:oka_update/oka_update.dart';

import 'frontend_protocol.dart';

/// The flutter cache layout: `<flutter>/bin/cache/{dart-sdk,artifacts}`.
/// A bare binary name (`flutter`) is resolved via PATH — every path handed
/// to the frontend must be ABSOLUTE or the compile dies on a relative
/// sdk-root (the process CWD is the runner's, not the flutter root's).
(String dartSdk, String frontend, String patchedSdk) flutterToolchainPaths(
  String flutterBin,
) {
  var bin = flutterBin;
  if (!bin.contains('/')) {
    final which = Process.runSync('which', [bin]);
    if (which.exitCode == 0) {
      bin = (which.stdout as String).trim();
    }
  }
  final cache =
      '${File(bin).parent.parent.path}/bin/cache'; // <flutter>/bin/cache
  final dartSdk = '$cache/dart-sdk';
  return (
    dartSdk,
    '$dartSdk/bin/snapshots/frontend_server_aot.dart.snapshot',
    '$cache/artifacts/engine/common/flutter_patched_sdk',
  );
}

/// Compiles through a fresh frontend and validates its terminal error report.
/// The successful temporary artifact is consumed/retired by the calling owner.
/// A failed compile removes only its own temporary directory. The artifact
/// contains the entry library's compiled component; this one-shot factory
/// does not retain an incremental compiler baseline across calls.
UnitDeltaCompiler flutterFrontendDeltaCompiler(
  String frontend,
  String dartSdk,
  String patchedSdk,
  String packages,
) => (request) async {
  final directory = Directory.systemTemp.createTempSync('oka-ff-delta');
  final out = '${directory.path}/unit.delta.dill';
  try {
    final r = await Process.run('$dartSdk/bin/dartaotruntime', [
      frontend,
      '--sdk-root=$patchedSdk',
      '--target=flutter',
      '--incremental',
      '--packages=$packages',
      '--output-dill=$out',
      '--output-incremental-dill=$out.incremental.dill',
      request.patchedFiles.first,
    ]);
    final terminal = parseFrontendResult(r.stdout as String);
    if (r.exitCode != 0 ||
        terminal == null ||
        terminal.errors != 0 ||
        terminal.path != out ||
        !File(out).existsSync() ||
        File(out).lengthSync() == 0) {
      throw StateError(
        'frontend delta compile failed (exit ${r.exitCode}): ${r.stdout}\n${r.stderr}',
      );
    }
    return DeltaArtifact(path: out, bytes: File(out).lengthSync());
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
  }
};
