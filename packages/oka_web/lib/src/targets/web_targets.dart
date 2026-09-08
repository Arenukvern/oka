/// The web targets (ADR-0016 §2): `web-shell` (compose + emit) and
/// `web-build` (explicit, honest delegation to `flutter build web`).
///
/// Targets are typed, const-constructible values composed from the
/// entrypoint (ADR-0015) — no CLI changes, ever.
library;

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

/// The `web-shell` target: compose + emit the shell.
///
/// Dry-runnable by construction — [compile] produces
/// [ValidateWebShellStep] → [EmitWebShellStep], and the emit step's
/// summary data carries the composed-shell render so `oka explain`
/// (W1 wiring) shows the shell before anything writes.
@immutable
class WebShellTarget extends Target {
  const WebShellTarget({
    required this.spec,
    this.contributions = const [],
    this.emitter = const GenerateShellEmitter(),
    this.webDir = 'web',
  });

  /// The project shell spec.
  final WebShellSpec spec;

  /// Explicitly composed contributions (store SDKs, ads, …).
  final List<WebShellContribution> contributions;

  /// The emitter (ADR-0016 "how" seam; `generate` by default).
  final ShellEmitter emitter;

  /// Web directory, relative to the project root (`web` by default).
  final String webDir;

  /// The composed shell (pure — reused by [compile] and tooling).
  WebShell compose() => WebShell(spec: spec, contributions: contributions);

  /// Target name: `web-shell`.
  @override
  String get name => 'web-shell';

  /// Explain-text: what the target composes/emits, with the emitter name
  /// and owned paths.
  @override
  String get description =>
      'Compose and emit the web shell (${emitter.name} emitter: '
      '${emitter.ownedPaths.join(', ')}) — no Flutter invocation';

  /// Pure: the web keys this target owns, for oka.yaml override precedence
  /// visibility. Never reads the filesystem or environment.
  @override
  Map<String, dynamic> get configOverrides => {
        'web': {
          'base_href': compose().baseHref,
          'emitter': emitter.name,
          'dir': webDir,
        },
      };

  /// Compile to the validate → emit step chain (no Flutter invocation).
  @override
  List<BuildStep> compile(final BuildContext ctx) {
    final shell = compose();
    final dir = p.isAbsolute(webDir)
        ? webDir
        : p.join(ctx.projectPath, webDir);
    return [
      ValidateWebShellStep(shell: shell, webDir: dir),
      EmitWebShellStep(emitter: emitter, webDir: dir),
    ];
  }

  /// ADR-0016 W1: the composed-shell render for `oka explain --targets` —
  /// pure (no I/O, no execution); the same value the emit step writes.
  @override
  List<String> explainDetails(final BuildContext ctx) {
    final shell = compose();
    final header = 'composed web shell (emitter "${emitter.name}" owns: '
        '${emitter.ownedPaths.join(', ')}; post-emit drift gate: re-render '
        'must be a no-op):';
    return [header, ...shell.describeLines()];
  }

  /// Debug string: emitter name plus contribution count.
  @override
  String toString() =>
      'WebShellTarget(${emitter.name}, ${contributions.length} contributions)';
}

/// The `web-build` target: an **explicit, honest delegation** to
/// `flutter build web`.
///
/// This does not violate the no-Gradle law (ADR-0001 governs the Android
/// default path; web has no oka-owned compile path to protect). The
/// delegation is named as delegation in [description] — never claimed as
/// an oka pipeline. Base href comes from the target config (or a
/// contribution override) and is passed as `--base-href`.
@immutable
class WebBuildTarget extends Target {
  const WebBuildTarget({
    this.baseHref = '',
    this.contributions = const [],
    this.extraArgs = const [],
  });

  /// Base href passed to `flutter build web --base-href` (empty = omit).
  final String baseHref;

  /// Contributions whose baseHref / dart-define overrides apply
  /// (last declaration wins).
  final List<WebShellContribution> contributions;

  /// Extra args appended verbatim (e.g. `--wasm`).
  final List<String> extraArgs;

  /// The effective base href: the last contribution override wins over
  /// the typed config value.
  String get effectiveBaseHref {
    for (final c in contributions.reversed) {
      final override = c.baseHref;
      if (override != null && override.isNotEmpty) return override;
    }
    return baseHref;
  }

  /// Target name: `web-build`.
  @override
  String get name => 'web-build';

  /// Explain-text: names the delegation to `flutter build web` honestly —
  /// never claimed as an oka-owned pipeline.
  @override
  String get description =>
      'delegates to flutter build web (not an oka-owned pipeline) — '
      'composes base href and dart-defines from the web shell config';

  /// Pure: the keys this target owns.
  @override
  Map<String, dynamic> get configOverrides => {
        'web': {
          'base_href': effectiveBaseHref,
          'delegation': 'flutter build web',
        },
      };

  /// Compile to the [FlutterWebBuildStep] delegation.
  @override
  List<BuildStep> compile(final BuildContext ctx) =>
      [FlutterWebBuildStep(baseHref: effectiveBaseHref, extraArgs: extraArgs)];

  /// Debug string: effective base href plus the delegation marker.
  @override
  String toString() =>
      "WebBuildTarget(baseHref: '$effectiveBaseHref', delegation)";
}
