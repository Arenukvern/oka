/// Staging for the directory-artifact convention (ADR-0016 §2): web deploy
/// targets consume a **directory** path as the publish artifact.
///
/// Mirrors the `StageAabStep` precedence contract from the file-artifact
/// targets (ADR-0014), applied to directories: the typed [sourceDir]
/// override wins; then an upstream artifact with the same id already in
/// state (e.g. `web-build-output` provided by `FlutterWebBuildStep`); the
/// fallback is Flutter's default web output location `<project>/build/web`.
///
/// The *existence/kind* check happens in the deploy steps (dry-run must
/// succeed without a produced build — the plan describes what a real run
/// would deploy).
library;

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../steps/flutter_web_build_step.dart';

/// Stages the publish directory artifact ([artifactId]).
///
/// Pure with respect to the filesystem: it only *resolves and records a
/// path* in [PipelineState] — it never creates, validates, or uploads
/// anything. Deploy steps own the existence checks so a dry run succeeds
/// without a build.
class StageWebDirectoryStep extends BuildStep {
  /// Wraps the artifact id and optional typed source override.
  StageWebDirectoryStep({
    required this.artifactId,
    this.sourceDir,
  });

  /// Default artifact id: the directory artifact produced by
  /// [FlutterWebBuildStep] (`web-build-output` → `build/web`).
  static const defaultDirectoryArtifactId = 'web-build-output';

  /// The directory artifact the deploy tail consumes.
  final String artifactId;

  /// Typed-config directory override (highest precedence). Null → state →
  /// Flutter's default web output location.
  final String? sourceDir;

  /// Step name: `stage-web-dir`.
  @override
  String get name => 'stage-web-dir';

  /// Produces the directory artifact.
  @override
  Set<Artifact<Object>> get provides => {Artifact<String>(artifactId)};

  /// Resolves the publish path (typed override → state → default web
  /// output) and records it in [PipelineState]; never touches the
  /// filesystem.
  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) {
    final path = sourceDir ?? _resolveStaged(ctx, state);
    if (path.isNotEmpty) state[artifactId] = path;
    return Future<StepResult>.value(StepResult.success());
  }

  /// State resolution (typed override already handled): an upstream
  /// artifact with [artifactId] wins over the default output layout.
  String _resolveStaged(final BuildContext ctx, final PipelineState state) {
    final existing = state[artifactId];
    if (existing is String && existing.isNotEmpty) return existing;
    return defaultWebOutput(ctx);
  }

  /// Flutter's default web output location: `<project>/build/web` (where
  /// `flutter build web` writes — keep in sync with FlutterWebBuildStep).
  static String defaultWebOutput(final BuildContext ctx) =>
      p.join(ctx.projectPath, 'build', 'web');
}
