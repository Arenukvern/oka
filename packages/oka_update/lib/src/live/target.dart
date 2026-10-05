/// Composable patch targets. A target is "a running program that can accept
/// a patch over a wire" — nothing more. The session composes any number of
/// them; adding a platform means adding a target, not changing the session.
library;

import 'spec.dart';

/// What the target did with the delta.
class ApplyOutcome {
  const ApplyOutcome({
    required this.ok,
    required this.mode,
    this.error,
    this.wire = const {},
  });

  final bool ok;

  /// Which wire method carried the delta, e.g. `reloadKernel`,
  /// `reloadSources(rootLibUri)`, `dwds reloadSources`,
  /// `staged-next-launch`.
  final String mode;
  final String? error;

  /// Raw wire facts worth keeping in a receipt (report, counts).
  final Map<String, Object?> wire;
}

abstract class LivePatchTarget {
  String get id;
  String get kind;

  /// Connects to the running program. Idempotent per run.
  Future<void> connect();

  /// Applies the compiled unit delta. For web targets the platform
  /// toolchain recompiles from source before this is called; the delta is
  /// then advisory (bytes are reported, not consumed).
  Future<ApplyOutcome> apply({
    required String unit,
    required String deltaPath,
    required int deltaBytes,
  });

  /// Evaluates a probe expression in the running program; returns its
  /// value as a string.
  Future<String> evaluate(ProbeSpec probe);

  /// The dev-session asset lane (G-RUN): write [bytes] into the engine's
  /// asset directory under [assetKey] and evict the app's caches. Shader
  /// bundles ([shader], compiled `.frag` → `.iplr`) evict engine-side via
  /// `ext.ui.window.reinitializeShader`; everything else via
  /// `ext.flutter.evict`. Targets whose platform cannot take asset
  /// changes refuse in the outcome (web: a page reload is the change;
  /// staged AOT: assets ride the snapshot lane) — they never throw for an
  /// expected refusal.
  Future<ApplyOutcome> syncAsset({
    required String assetKey,
    required List<int> bytes,
    required String flutterAssetsDir,
    bool shader = false,
  });

  Future<void> close();
}
