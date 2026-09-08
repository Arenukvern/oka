/// ADR-0016 flagship example — runnable CrazyGames composition replacing
/// branch-per-store web diffs.
///
/// This file IS the whole store-config surface: one composition root with
/// (a) the store shell spec, (b) the [CrazyGamesShellContribution], and
/// (c) the emit + build + deploy targets. No branch diffs, no hand-edited
/// HTML, no commented-out `<script>` blocks.
///
/// Run it (from `packages/oka_web`):
///
/// ```bash
/// dart run example/crazygames/compose_example.dart
/// ```
///
/// In the app repo, the same declarations live in `tool/oka_pipeline.dart`
/// and run as:
///
/// ```bash
/// oka explain                     # validated plan, shell render, no I/O
/// oka run web-shell               # compose + emit (generate or inject)
/// oka run web-build               # flutter build web (named delegation)
/// oka run publish-gh-pages        # push build/web to gh-pages
/// ```
///
/// Pure composition — `main` only prints; the targets do I/O only when
/// actually run.
library;

import 'package:oka_core/oka_core.dart';
import 'package:oka_web/oka_web.dart';

import 'crazygames_contribution.dart';

/// Store naming — replaces the branch's title/meta diff hunk. The master
/// spec stays the project default; the store shell spec is composed per
/// target, in Dart, typed.
const WebShellSpec crazyGamesSpec = WebShellSpec(
  title: 'Word by Word — CrazyGames',
  description: 'Learn words by playing. Word by word.',
);

/// The store contribution (see `crazygames_contribution.dart`).
const CrazyGamesShellContribution crazyGames = CrazyGamesShellContribution();

/// (a) New-app path: the `generate` emitter OWNS `web/index.html` +
/// `web/manifest.json` (generated-content banners). Flutter upgrades stop
/// being a per-branch merge tax — the template lives in one replaceable
/// class, validated by the post-emit drift gate (ADR-0016 W1).
const WebShellTarget crazyGamesGenerateShell = WebShellTarget(
  spec: crazyGamesSpec,
  contributions: [crazyGames],
);

/// (a) Legacy-app migration path (marker migration): the `inject` emitter
/// adds ONLY the composed entries between the
/// `<!-- oka:begin:head -->` / `<!-- oka:end:head -->` markers and leaves
/// the hand-maintained file (custom JS, analytics) byte-identical outside
/// them. Use this while migrating; switch to [crazyGamesGenerateShell]
/// when the hand-tuned regions are absorbed. Note the SSOT split: with
/// `inject`, the spec title/description/icons remain owned by the
/// hand-written file — the emitter injects head/body entries only.
const WebShellTarget crazyGamesInjectShell = WebShellTarget(
  spec: crazyGamesSpec,
  contributions: [crazyGames],
  emitter: InjectShellEmitter(),
);

/// (b) The web build — an explicit, honest delegation to
/// `flutter build web`; base href + dart-defines compose from the same
/// contribution values (no second source of truth).
const WebBuildTarget crazyGamesWebBuild = WebBuildTarget(
  contributions: [crazyGames],
);

/// (b) The deploy tail that replaces the `gh-pages` branch workflow:
/// pushes the built web directory to `origin/gh-pages`. Destructive and
/// ambient-auth — `dryRun` defaults to `true`; the explicit flip below is
/// the "this machine may really push" decision.
const GhPagesDeployTarget crazyGamesGhPages = GhPagesDeployTarget(
  // dryRun: false — flip explicitly when a real push is intended.
);

/// The one-target chain that replaces per-store release branches: build
/// the web output, then push it to gh-pages. `oka run web-deploy` — no
/// branch checkout, no template merge, no manual `git subtree push`.
///
/// `Target` is abstract in oka_core (targets are typed values compiled to
/// validated step chains, ADR-0015) — a composed chain is a small concrete
/// subclass, const-constructible like every target.
class WebDeployTarget extends Target {
  const WebDeployTarget();

  @override
  String get name => 'web-deploy';

  @override
  String get description => 'flutter build web + push build/web to '
      'gh-pages (replaces per-store release branches)';

  @override
  List<BuildStep> compile(final BuildContext ctx) => [
        ...crazyGamesWebBuild.compile(ctx),
        ...crazyGamesGhPages.compile(ctx),
      ];

  @override
  List<String> explainDetails(final BuildContext ctx) => const [
        'composed chain: web-build (delegation) → publish-gh-pages (dry run)',
      ];
}

const WebDeployTarget crazyGamesWebDeploy = WebDeployTarget();

void main() {
  // The composed shell — exactly what `oka explain --targets` shows before
  // anything writes (WebShellTarget.explainDetails carries the same
  // render). requiredSdkGlobal is visible per entry (ADR-0016 W1).
  final WebShell shell = crazyGamesGenerateShell.compose();
  print(shell.describeLines().join('\n'));

  // The target chain — every step validated at composition time before
  // any tool runs (ADR-0015).
  final List<BuildStep> chain = crazyGamesWebDeploy.compile(_dryContext());
  print('\nweb-deploy chain:');
  for (final BuildStep step in chain) {
    print('  - ${step.name}');
  }
}

/// A minimal context for the demo chain print — no tool runs here.
BuildContext _dryContext() => const BuildContext(
      projectPath: '.',
      buildDir: '.oka/build',
      mode: BuildMode.release,
      config: OkaConfig.empty,
    );
