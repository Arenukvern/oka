import '../config/build_context.dart';
import '../pipeline/pipeline.dart';

/// Stages the Android App Bundle publish artifact
/// (`Artifact<String>('aab-path')` — the shared publish contract, ADR-0014).
///
/// Store targets consume the same staged artifact — staging is a *product*
/// concern (ADR-0023 §2: Android delivery primitives are shared), not a
/// per-store copy.
///
/// Precedence: the typed [artifactPath] override wins; then an explicit
/// `aab-path` upstream (already staged); then the Android build's shared
/// artifact slot `apk_path` (an AAB build); the fallback is oka's default
/// AAB output location `<buildDir>/aab/app-<mode>.aab` — where `oka build
/// aab` writes the signed bundle. The *existence* check happens downstream
/// (dry-run must succeed without a produced AAB — the plan describes what a
/// real run would upload).
class StageAabStep extends BuildStep {
  /// Wraps the optional typed path override.
  StageAabStep({this.artifactPath});

  /// The publish artifact the upload tail consumes.
  static const Artifact<String> aab = Artifact<String>('aab-path');

  /// Typed-config path override (null → state / default layout).
  final String? artifactPath;

  /// Step name: `stage-aab`.
  @override
  String get name => 'stage-aab';

  /// Provides the AAB path artifact.
  @override
  Set<Artifact<Object>> get provides => {aab};

  /// Resolves the AAB path (typed override → state → default AAB output)
  /// and records it in [PipelineState]; never touches the filesystem.
  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) {
    final path = artifactPath ?? _resolveStaged(ctx, state);
    if (path.isNotEmpty) state[aab.id] = path;
    return Future<StepResult>.value(StepResult.success());
  }

  /// State resolution (typed override already handled): an upstream
  /// `aab-path` wins over the Android build's shared `apk_path` slot;
  /// the fallback is oka's real AAB output path.
  String _resolveStaged(final BuildContext ctx, final PipelineState state) {
    final existing = state[aab.id];
    if (existing is String && existing.isNotEmpty) return existing;
    final androidAab = state['apk_path'];
    if (androidAab is String && androidAab.isNotEmpty) return androidAab;
    return defaultAabPath(ctx);
  }

  /// oka's default AAB output location: `<buildDir>/aab/app-<mode>.aab`
  /// (matches `packageAndSignAab` in oka_android — keep in sync).
  static String defaultAabPath(final BuildContext ctx) =>
      '${ctx.buildDir}/aab/app-${ctx.mode.name}.aab';
}
