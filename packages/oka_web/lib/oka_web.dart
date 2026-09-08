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
/// check — before any tool runs (ADR-0015). The W1 drift gate
/// ([checkShellDrift]) is a pure comparator over the emitter's owned
/// paths, wired as a post-emit idempotency check in [EmitWebShellStep]
/// and surfaced to `oka explain --targets` through the generic
/// `Target.explainDetails` hook (ADR-0016 W1). The flagship third-party
/// example lives in `example/crazygames/` (ADR-0016 §3).
///
/// Browser session targets (ADR-0017): [ChromeSessionTarget] ensures a
/// Chrome session answering CDP (idempotent reuse, plain-HTTP readiness
/// probe — never a CDP client) and provides the session-handle artifacts
/// (`session-chrome-<name>-handle`, `session-chrome-<name>-cdp-port`) over
/// the same Target + artifact contract; [BrowserSessionSpec] is the typed
/// "what" seam and [chromeWebMcp] the first-party profile.
library;

export 'src/composition.dart';
export 'src/contribution.dart';
export 'src/drift.dart';
export 'src/emitter.dart';
export 'src/emitters/generate_emitter.dart';
export 'src/emitters/inject_emitter.dart';
export 'src/emitters/render.dart';
export 'src/publish/gh_pages_deploy_target.dart';
export 'src/publish/itch_deploy_target.dart';
export 'src/publish/stage_web_dir_step.dart';
export 'src/session/browser_session_spec.dart';
export 'src/session/chrome_session_target.dart';
export 'src/session/profiles.dart';
export 'src/spec/body_entry.dart';
export 'src/spec/head_entry.dart';
export 'src/spec/web_shell_spec.dart';
export 'src/steps/emit_web_shell_step.dart';
export 'src/steps/flutter_web_build_step.dart';
export 'src/steps/web_zip_step.dart';
export 'src/targets/web_targets.dart';
export 'src/validation.dart';
