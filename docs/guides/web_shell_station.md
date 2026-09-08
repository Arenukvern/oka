# Web Shell Station

The web shell station (`oka_web`) is oka's configuration-and-distribution
layer for web apps (ADR-0016). It is **explicitly NOT a platform
pipeline**: the compile step stays an honest, named delegation to
`flutter build web` (`WebBuildTarget`), and oka never claims to own the
web compile path. What oka owns is the shell — the per-store
`web/index.html` edits that today live in hand-maintained branches — as
typed, composable, drift-checked Dart values.

## The two seams

- **Contribution (what)** — a `WebShellContribution` is a typed,
  const-constructible description of what a store (or the project) adds to
  the shell: ordered head entries with declarative phases
  (`preconnect` → `storeSdk` → `app`), body entries, PWA manifest
  overrides, and optional base-href / dart-define overrides. Store
  packages ship these as const values alongside their runtime adapters;
  the user composes them explicitly in the entrypoint (no hidden merging,
  ADR-0010).
- **Emitter (how)** — a `ShellEmitter` renders the composed `WebShell`
  and declares what it owns (`ownedPaths`). Two first-party emitters:
  - `GenerateShellEmitter` (default) — oka owns `web/index.html` +
    `web/manifest.json`, written with generated-content banners. Flutter
    template-version coupling is contained in this one class.
  - `InjectShellEmitter` — injects composed entries between explicit
    markers (`<!-- oka:begin:head -->` … `<!-- oka:end:head -->`, body
    equivalents) in a hand-maintained `index.html`. Fails with an
    actionable message when markers are absent; never rewrites anything
    outside the markers.

## Quickstart

Compose a spec + contribution into a `WebShellTarget` and run it:

```dart
import 'package:oka_core/oka_core.dart';
import 'package:oka_web/oka_web.dart';

Oka(
  pipelines: [],
  targets: [
    // 1. Compose + emit the shell into web/ (typed, drift-checked).
    WebShellTarget(
      spec: WebShellSpec(title: 'My Game'),
      contributions: [MyStoreShellContribution()],
    ),
    // 2. Delegate the compile: flutter build web → build/web.
    WebBuildTarget(),
  ],
)
```

```bash
oka explain --targets   # validated plan + composed-shell render, no I/O
oka run web-shell       # compose + emit
oka run web-build       # flutter build web (named delegation)
```

A complete in-repo example lives in
`packages/oka_web/example/crazygames/` — a `CrazyGamesShellContribution`
with the store SDK script, a preconnect, and the `requiredSdkGlobal`
declaration, composed into shell/build/deploy targets.

## Generate vs inject, and the migration path

Legacy apps migrate in three steps — **markers → inject → optional
generate**:

1. **Add markers** to your hand-maintained `web/index.html` where oka may
   manage entries:

   ```html
   <head>
     ...your hand-maintained tags...
     <!-- oka:begin:head -->
     <!-- oka:end:head -->
   </head>
   <body>
     <!-- oka:begin:body -->
     <!-- oka:end:body -->
   </body>
   ```

2. **Inject**: compose the shell with `InjectShellEmitter()`. Emission
   rewrites ONLY the marker regions, byte-for-byte preserving everything
   else (your custom JS, analytics, frozen bootstrap). Re-emission is a
   no-op — the drift gate verifies it (below).
3. **Optionally generate**: once the hand-tuned regions are absorbed into
   the composition (spec fields, contributions), switch to the default
   `GenerateShellEmitter`, which owns the whole file and ends the
   hand-maintained-template era.

### The SSOT split under `inject`

With the inject emitter, the emitter owns **head/body entries only**.
The spec's identity fields — title, description, icons, manifest — are
rendered by the `generate` emitter but **not** injected: your
hand-written file remains the source of truth for them while you
migrate. That split is deliberate: injection never silently rewrites
unowned regions, so spec identity changes do not appear in an injected
file until you either edit the file yourself or switch to `generate`.

### Quote-style caveat

Injected inline entries are declarative renders, not imitations of your
legacy file. If your hand-written HTML uses different quoting or
whitespace (e.g. double-quoted attributes inside inline scripts), a
byte-compare against the legacy file will not match exactly — injection
owns the marker region, so the region's exact bytes come from the
composition render. Compare *outside* the markers when auditing a
migration; the drift gate does this for you.

## requiredSdkGlobal: build-time ↔ runtime reconciliation

A store's SDK script defines a well-known global (`window.CrazyGames`,
`YaGames`, …). The contribution declares it once as
`WebScriptEntry.requiredSdkGlobal`; the runtime adapter declares the
same global as its `expectedSdkGlobal`. ADR-0016 §3's point: these are
**the same fact** declared in the two places that need it, reconciled by
the shell gate and `oka doctor` instead of duplicated and drifting. The
declaration is visible wherever the composition is shown —
`WebShell.describeLines()` renders `requiredSdkGlobal=` per script
entry, and `oka explain --targets` prints that render via the target's
pure `explainDetails` (see the CrazyGames example test for the exact
expectation).

## The drift gate

Every emitter declares what it owns (`ownedPaths`). The W1 drift gate
(`checkShellDrift` in `package:oka_web/oka_web.dart`) is a pure
comparator: re-render the composition and compare against the current
on-disk contents of the owned paths.

- **Generate**: the owned files must equal the full re-render.
- **Inject**: re-emission must be a **no-op** on the current file — the
  marker regions must already match the composition; everything outside
  is untouched (and unowned).

A drift report names, per owned path: what's owned, what differs (first
differing line), and what to run (`oka run web-shell`).

The gate runs automatically as a **post-emit idempotency check** inside
`EmitWebShellStep`: after writing, the step re-reads the owned paths and
re-renders; if the written bytes are not the composition's re-render,
the step fails naming the drift. To audit without emitting, call
`checkShellDrift(shell:, emitter:, currentFiles:)` directly from your
own tooling — it is pure (no I/O inside the comparison; pass the file
contents in as strings).

## Deploy targets

Web deploy targets are `PublishTarget`s (ADR-0014) that consume a
**directory** artifact — the directory-artifact convention (ADR-0016
§2): `artifactId` references a directory path (`build/web` by default),
declared via `PublishTarget.artifactIsDirectory` and asserted by the
publish conformance suite.

- **`publish-gh-pages`** — pushes the build directory to a `gh-pages`
  branch via a temporary worktree with **ambient git auth only**.
- **`publish-itch`** — `butler push <dir> <user>/<game>:<channel>`; the
  optional butler API key is surfaced only as a redacting
  `CredentialRef`.
- **`WebZipStep`** — generic directory → zip file artifact for stores
  that upload archives.

Both deploy targets default to **dry run**: deploys are destructive, so
a real push is always an explicit `dryRun: false` flip. `oka explain
--targets` shows the deploy posture (dry-run default, endpoint,
directory artifact) via the same pure `explainDetails` hook.
