/// Web shell station for oka (ADR-0016): typed shell composition, a
/// replaceable emitter seam, and the `web-shell` / `web-build` targets.
///
/// Web is explicitly **NOT** a `PlatformPipeline` — the compile step is an
/// honest, named delegation to `flutter build web`; oka owns only the
/// configuration and distribution layer (the shell).
///
/// Two seams, composed explicitly in the entrypoint (ADR-0010 — no hidden
/// merging):
///
/// 1. **Contribution (what)** — [WebShellContribution]s shipped by the
///    project, by store packages (const values), and by oka's own
///    stations: ordered [WebHeadEntry]s with declarative phases
///    ([WebHeadPhase] `preconnect` → `storeSdk` → `app`), body entries,
///    PWA manifest overrides, base-href / dart-define overrides.
/// 2. **Emitter (how)** — a [ShellEmitter] renders the composed
///    [WebShell] and declares what it owns ([ShellEmitter.ownedPaths]).
///    First-party: [GenerateShellEmitter] (default; owns `index.html` +
///    `manifest.json`) and [InjectShellEmitter] (marker-based injection
///    into hand-maintained files; fails actionably without markers).
///
/// Targets ([WebShellTarget], [WebBuildTarget]) compile to
/// build-step chains validated by oka_core's composition-time artifact
/// check — before any tool runs (ADR-0015).
library;

export 'src/composition.dart';
export 'src/contribution.dart';
export 'src/emitter.dart';
export 'src/emitters/generate_emitter.dart';
export 'src/emitters/inject_emitter.dart';
export 'src/emitters/render.dart';
export 'src/spec/body_entry.dart';
export 'src/spec/head_entry.dart';
export 'src/spec/web_shell_spec.dart';
export 'src/steps/emit_web_shell_step.dart';
export 'src/steps/flutter_web_build_step.dart';
export 'src/steps/web_zip_step.dart';
export 'src/targets/web_targets.dart';
export 'src/validation.dart';
