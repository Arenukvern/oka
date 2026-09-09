# oka_web

Web shell station for [oka](https://github.com/Arenukvern/oka) (ADR-0016).
Typed, const-constructible shell composition — head entries with
declarative ordering phases, body entries, PWA manifest fields, base-href
and dart-define overrides — plus a replaceable **emitter** seam and two
first-party emitters:

- `GenerateShellEmitter` (default) — oka owns `web/index.html` +
  `web/manifest.json`, written with generated-content banners. Flutter
  template-version coupling is contained in this one class.
- `InjectShellEmitter` — for apps with a hand-maintained `web/index.html`.
  Injects composed entries between explicit markers
  (`<!-- oka:begin:head -->` … `<!-- oka:end:head -->`); fails with an
  actionable message when markers are absent — never silently rewrites
  unowned regions.

**Web is explicitly NOT a `PlatformPipeline`.** The `web-build` target is
an honest, named delegation to `flutter build web`; the `web-shell` target
composes and emits the shell without invoking Flutter at all.

Store packages (Yandex Games, CrazyGames, VK Play, itch.io, …) ship const
`WebShellContribution`s — ordered SDK scripts, preconnects, per-store
base hrefs — composed explicitly by the user in the entrypoint (no hidden
merging, ADR-0010). The in-repo flagship example is the CrazyGames
contribution: [`example/crazygames/`](example/crazygames/) — the
third-party pattern pilot (a store package ships exactly this shape
alongside its runtime adapter once `oka_web` is published). The former
Yandex Games pilot lives in the migrating app's own repo, adopted via the
inject emitter.

## Drift gate (ADR-0016 W1)

Every emitter declares what it owns (`ownedPaths`); the pure
`checkShellDrift` comparator re-renders the composition and reports any
owned region on disk that is not the re-render (what's owned, what
differs, what to run). `EmitWebShellStep` runs it automatically as a
post-emit idempotency check — the written bytes must be the
composition's re-render. See `docs/guides/web_shell_station.mdx` for the
full guide (migration path, SSOT split, `requiredSdkGlobal`
reconciliation, deploy posture).

## Deploy targets (ADR-0016 W2)

Web deploy targets are `PublishTarget`s (ADR-0014) that consume a
**directory** artifact — the directory-artifact convention: `artifactId`
references a directory path (`build/web` by default), declared via
`PublishTarget.artifactIsDirectory` and asserted by the publish
conformance suite. Both default to **dry-run**: deploys are destructive,
so a real push is always an explicit `dryRun: false` flip.

The one-codebase composition (no per-store branches):

```dart
Oka(
  pipelines: [],
  targets: [
    // 1. Compose + emit the shell into web/ (typed, drift-checked).
    WebShellTarget(spec: ..., contributions: [...]),
    // 2. Delegate the compile: flutter build web → build/web.
    WebBuildTarget(baseHref: '/my-app/'),
    // 3. Deploy targets over the produced directory artifact —
    //    run with `oka run publish-gh-pages` / `oka run publish-itch`.
    GhPagesDeployTarget(
      // dryRun: false, // flip explicitly when the plan looks right
    ),
    ItchDeployTarget(user: 'my-user', game: 'my-game'),
  ],
)
```

- **`publish-gh-pages`** — pushes the build directory to a `gh-pages`
  branch via a temporary `git worktree` and **ambient git auth only** (no
  token inputs, no interactive prompts: `GIT_TERMINAL_PROMPT=0`). Content
  sync wipes the worktree except `.git` (the default ignore set) and
  copies the source; empty diffs fail actionably (allow-empty commits are
  disabled as code). Config: `branch` (`gh-pages`), `remote` (`origin`),
  `commitMessage`, `subdirectory` filter, `sourceDir`,
  `directoryArtifactId`.
- **`publish-itch`** — `butler push <dir> <user>/<game>:<channel>` via the
  injectable process runner. The optional butler API key is surfaced only
  as a redacting `CredentialRef` (`BUTLER_API_KEY` env var, typed
  `apiKeyPath` file, or the well-known file
  `~/.oka/credentials/itch/butler-api-key`); the value is passed to the
  butler child process via its environment and never logged or stored.
- **`WebZipStep`** — generic directory artifact → zip file artifact for
  stores that upload archives (deterministic entry order).

Targets stay independently composable: point `sourceDir` at any directory,
or compose a custom one-chain build+deploy `Target` from the exported
steps (`FlutterWebBuildStep` → `GhPagesDeployTarget(...).uploadStep(ctx)`)
— nothing auto-couples.
