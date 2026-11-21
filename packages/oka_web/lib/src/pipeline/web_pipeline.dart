import 'package:meta/meta.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import '../composition.dart';
import '../contribution.dart';
import '../emitter.dart';
import '../emitters/generate_emitter.dart';
import '../spec/web_shell_spec.dart';
import '../steps/emit_web_shell_step.dart';
import '../steps/flutter_web_build_step.dart';

/// The web platform pipeline (ADR-0055): compose + emit the shell, then
/// the honest `flutter build web` delegation — one [PlatformPipeline] a
/// web delivery can reference.
///
/// Like the web targets ([WebShellTarget]/[WebBuildTarget]), this pipeline
/// is composition over the ADR-0016 station: the shell emit is oka-owned,
/// the compile is delegation named as delegation.
///
/// ```dart
/// final webPipeline = WebPipeline(
///   spec: WebShellSpec(title: 'My App'),
///   contributions: [myPortalSdk],
///   baseHref: '/my-app/',
/// );
///
/// Oka(
///   targets: [
///     Delivery(
///       name: 'web-gh-pages',
///       pipeline: webPipeline,
///       channel: GhPagesDeployTarget(baseHref: '/my-app/'),
///     ),
///   ],
/// )
/// ```
@immutable
class WebPipeline implements PlatformPipeline {
  const WebPipeline({
    required this.spec,
    this.contributions = const [],
    this.emitter = const GenerateShellEmitter(),
    this.baseHref = '',
    this.extraBuildArgs = const [],
    this.webDir = 'web',
    this.configOverrides = const {},
  });

  /// The project shell spec.
  final WebShellSpec spec;

  /// Explicitly composed contributions (portal SDKs, store overlays —
  /// the web face of the ADR-0055 overlay axis).
  final List<WebShellContribution> contributions;

  /// The shell emitter (`generate` by default).
  final ShellEmitter emitter;

  /// Base href passed to `flutter build web --base-href` (empty = omit).
  final String baseHref;

  /// Extra args appended to the flutter invocation (e.g. `--wasm`).
  final List<String> extraBuildArgs;

  /// Web directory, relative to the project root (`web` by default).
  final String webDir;

  @override
  final Map<String, dynamic> configOverrides;

  @override
  String get platform => 'web';

  /// The composed shell (pure — reused by the run and by tooling).
  WebShell compose() => WebShell(spec: spec, contributions: contributions);

  /// The effective base href: the last contribution override wins over
  /// the typed value (ADR-0016 explicit-composition law).
  String get effectiveBaseHref {
    for (final c in contributions.reversed) {
      final override = c.baseHref;
      if (override != null && override.isNotEmpty) return override;
    }
    return baseHref;
  }

  @override
  Future<StepResult> run(BuildContext ctx) {
    final dir = p.isAbsolute(webDir) ? webDir : p.join(ctx.projectPath, webDir);
    final pipeline = Pipeline([
      ValidateWebShellStep(shell: compose(), webDir: dir),
      EmitWebShellStep(emitter: emitter, webDir: dir),
      FlutterWebBuildStep(
        baseHref: effectiveBaseHref,
        extraArgs: extraBuildArgs,
      ),
    ], verbose: ctx.verbose);
    return pipeline.run(ctx);
  }
}
