/// The honest delegation step (ADR-0016 §2): `flutter build web`.
///
/// Web's compile step needs nothing oka-shaped (ADR-0016 context) — this
/// step invokes Flutter's own web build via oka_core's injectable process
/// runner and reports the outcome. It is a delegation, named as
/// delegation, never claimed as an oka-owned pipeline.
library;

import 'package:meta/meta.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

/// Runs `flutter build web` with the composed base href and dart-defines.
///
/// Arguments:
/// - `--base-href=<href>` when [baseHref] is non-empty (and formatted);
/// - `--dart-define=<k>=<v>` for every build-context define;
/// - extra args from [extraArgs] (appended verbatim, e.g. `--wasm`).
@immutable
class FlutterWebBuildStep extends BuildStep {
  /// Wraps the base href and extra args.
  FlutterWebBuildStep({this.baseHref = '', this.extraArgs = const []});

  /// The build output directory artifact (`build/web`).
  static const webBuildOutput = Artifact<String>('web-build-output');

  /// Base href passed as `--base-href` (empty = flag omitted; Flutter
  /// serves from root).
  final String baseHref;

  /// Extra args appended verbatim (e.g. `--wasm`, `--source-maps`).
  final List<String> extraArgs;

  /// Step name: `flutter-web-build`.
  @override
  String get name => 'flutter-web-build';

  /// Provides the `build/web` directory artifact.
  @override
  Set<Artifact<Object>> get provides => {webBuildOutput};

  /// The resolved argument vector (pure — tested directly).
  List<String> buildArgs(final BuildContext ctx) => [
        'build',
        'web',
        if (baseHref.isNotEmpty) '--base-href=$baseHref',
        for (final e in ctx.dartDefines.entries)
          '--dart-define=${e.key}=${e.value}',
        ...extraArgs,
      ];

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final executable = ctx.flutterSdkPath.isEmpty
        ? 'flutter'
        : p.join(ctx.flutterSdkPath, 'bin', 'flutter');
    final args = buildArgs(ctx);
    ctx.log('delegating to flutter build web — '
        'NOT an oka-owned pipeline (ADR-0016)');
    final result = await ctx.runner.run(
      executable,
      args,
      workingDirectory: ctx.projectPath,
    );
    if (!result.ok) {
      return StepResult.failure(
        'flutter build web failed (exit ${result.exitCode}):\n'
        '${result.stderr}\n${result.stdout}',
      );
    }
    state[webBuildOutput.id] = p.join(ctx.projectPath, 'build', 'web');
    return StepResult.success({
      'delegation': 'flutter build web (not an oka-owned pipeline)',
      'web-build-output': p.join(ctx.projectPath, 'build', 'web'),
    });
  }
}
