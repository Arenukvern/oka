/// Staged target: the AOT/restart lane. There is no live wire into an AOT
/// program — the runtime applies deferred unit artifacts when their load is
/// requested (`Dart_SetDeferredLoadHandler` / the standalone loader's
/// `<base>-<unit>.part.so` convention, see ADR-0031 §7). This target stages
/// the artifact next to the base snapshot and records the honest mode:
/// `staged-next-launch`.
library;

import 'dart:io';

import 'spec.dart';
import 'target.dart';
import 'vm_service_wire.dart';

class StagedTarget implements LivePatchTarget {
  StagedTarget({
    required this.id,
    required this.artifactsDir,
    required this.baseArtifact,
    required this.unitArtifact,
  });

  @override
  final String id;
  @override
  final String kind = 'staged';

  /// Directory holding the base snapshot and `<base>-<unit>.part.so` files.
  final String artifactsDir;

  /// Base artifact file name (e.g. `app.so`).
  final String baseArtifact;

  /// Patched unit artifact to stage (an AOT `app-aot-elf` part built by the
  /// compiler; the live JIT delta is NOT this).
  final String unitArtifact;

  @override
  Future<void> connect() async {
    final dir = Directory(artifactsDir);
    if (!dir.existsSync()) {
      throw LiveWireException('staged artifacts dir missing: $artifactsDir');
    }
    if (!File('$artifactsDir/$baseArtifact').existsSync()) {
      throw LiveWireException('base artifact missing: $baseArtifact');
    }
  }

  @override
  Future<ApplyOutcome> apply({
    required String unit,
    required String deltaPath,
    required int deltaBytes,
  }) async {
    final stagedName = '$artifactsDir/$baseArtifact-$unit.part.so';
    File(unitArtifact).copySync(stagedName);
    return ApplyOutcome(ok: true, mode: 'staged-next-launch', wire: {
      'staged': stagedName,
      'bytes': File(stagedName).lengthSync(),
      'note': 'applied by the runtime deferred loader at next load; '
          'no live wire exists into an AOT program',
    });
  }

  @override
  Future<String> evaluate(ProbeSpec probe) {
    throw LiveWireException(
        'staged targets have no live wire — probes run at next launch');
  }

  @override
  Future<ApplyOutcome> syncAsset({
    required String assetKey,
    required List<int> bytes,
    required String flutterAssetsDir,
    bool shader = false,
  }) async =>
      ApplyOutcome(
        ok: false,
        mode: 'assets-sync',
        error: 'AOT assets ride the snapshot lane — ship them with '
            '`oka ship --snapshot-from-build` (staged-next-launch)',
        wire: {'assetKey': assetKey},
      );

  @override
  Future<void> close() async {}
}
