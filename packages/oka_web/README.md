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

## Browser page attachments

`startBrowserPageSession` composes Chrome lifecycle and HTTP page discovery. It
defaults to headless and dispatches no activation command. Headed browser focus
behavior requires separate platform verification. The returned `browserHttpUrl`
lets another consumer use `BrowserSessionSpec(debugPort: endpoint.port)` to borrow
the running browser. Retain the owner session until all borrower pages are closed.
Borrowing preserves its process lease; borrower stop closes only its created page.
Stop sends one close request and observes target removal within its bounded
observation budget. An unobserved effect returns an error; repeated stop shares
the same outcome rather than replaying the mutation. Process ownership remains
separate from page ownership and application/Flutter focus.

## Built bundle identity

`WebBundleManifest.capture(directory)` inventories all regular output files in
canonical relative-path order with byte sizes and SHA-256 identities. Its JSON
representation validates its digest on restore. `matches(directory)` detects
changed/added/removed output, and `readVerified(directory, path)` returns only
bytes matching the recorded identity. Unknown paths, traversal and symlinks are
refused. This is an output artifact contract, not an input-cache key, atomic
filesystem snapshot, compiler reproducibility proof or browser cache policy.
The ecsly supervised preview consumes it before launching a browser and verifies
asset bytes before serving. Controlled negative response transformations have
separate source/served identities.

`WebBundleCachePolicy` separates HTTP reuse from artifact verification. The
noStore policy preserves baseline behavior. Revalidate emits the verified file's
strong ETag and private/max-age=0/must-revalidate headers; matching (including
weak/listed) If-None-Match can return 304 only after current bytes are verified.
A stale tag returns the verified current body. Mutable unversioned paths are not
declared immutable. The ecsly browser-cache supervisor scenario records server
requests, 304s, browser responses and a fresh-engine frame after reload.

`WebBundleSnapshot.load(directory: ..., manifest: ..., maxBytes: ...)` verifies
and retains immutable output bytes under an explicit payload budget. Subsequent
filesystem edits cannot change them; returned typed-byte views and their buffer
views refuse writes. Budget refers to asset payload, not VM/container overhead.
Verified file reads stop if their recorded byte limit is exceeded.

`assetUri(path)` and `readAssetUri(uri)` provide `/bundles/<digest>/<path>` routes
with exact bundle identity. The immutable cache policy may be used on those
routes; ordinary mutable entry URLs keep their own policy. Snapshot APIs do not
rewrite Flutter base href or loader URLs: composing an entire entry page under
the digest namespace requires a separate loader/base-URL integration. This is
immutable output serving, not a compiler input cache or reproducible-build claim.

For an explicit Flutter Wasm build, compose `WebBuildTarget(extraArgs: ['--wasm'])`
with your normal build arguments. Flutter also emits a JavaScript fallback; verify
the app's `const bool.fromEnvironment('dart.tool.dart2wasm')` at runtime rather
than inferring execution from output files. `WebIsolationPolicy.requireCorp` or
`credentialless` exposes opt-in COOP/COEP response headers independent of cache
policy; none is the default. Apply in the owning HTTP server and verify browser
`crossOriginIsolated` and actual resource loading. Configure JavaScript MIME types
for `.mjs` modules and application/wasm for Wasm binaries. Isolation/header
configuration alone does not establish renderer thread count or faster rendering.
See [Flutter's Wasm guide](https://docs.flutter.dev/platform-integration/web/wasm).
