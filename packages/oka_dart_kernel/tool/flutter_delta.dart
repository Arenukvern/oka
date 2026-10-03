/// The app's own frontend as a delta compiler (ADR-0035 §2e / ADR-0036):
/// kernel deltas only parse in a VM whose frontend produced them, so
/// every flutter-app target compiles through
/// `frontend_server_aot.dart.snapshot` + the flutter patched SDK.
library;

import 'dart:io';

import 'package:oka_update/oka_update.dart';

/// The flutter cache layout: <flutter>/bin/cache/{dart-sdk,artifacts}.
(String dartSdk, String frontend, String patchedSdk) flutterToolchainPaths(
    String flutterBin) {
  final cache =
      '${File(flutterBin).parent.parent.path}/bin/cache'; // <flutter>/bin/cache
  final dartSdk = '$cache/dart-sdk';
  return (
    dartSdk,
    '$dartSdk/bin/snapshots/frontend_server_aot.dart.snapshot',
    '$cache/artifacts/engine/common/flutter_patched_sdk',
  );
}

/// Compiles the unit delta with the app's own frontend server. The delta
/// is the entry library's recompiled set at the current (marked) source
/// state — exactly what the session expects as `patchedFiles`.
UnitDeltaCompiler flutterFrontendDeltaCompiler(
    String frontend, String dartSdk, String patchedSdk, String packages) {
  return (request) async {
    final out =
        '${Directory.systemTemp.createTempSync('oka-ff-delta').path}'
        '/${request.unit}.delta.dill';
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
    if (!File(out).existsSync()) {
      throw StateError(
          'frontend delta compile failed: ${r.stdout}\n${r.stderr}');
    }
    return DeltaArtifact(path: out, bytes: File(out).lengthSync());
  };
}
