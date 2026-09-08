# Changelog

## 0.2.0

- Deploy targets (ADR-0016 W2): `GhPagesDeployTarget` (`publish-gh-pages`,
  git-worktree deploy to a `gh-pages` branch with **ambient git auth only** —
  no token inputs, prompt-free git env, allow-empty commits disabled as code,
  optional `subdirectory` filter) and `ItchDeployTarget` (`publish-itch`,
  `butler push DIR USER/GAME:CHANNEL` with the API key surfaced only as a
  redacting `CredentialRef` — `BUTLER_API_KEY` env var or well-known file;
  the value is never logged or stored). Both consume a **directory**
  artifact (`web-build-output` → `build/web` by default; typed `sourceDir`
  override), declare `artifactIsDirectory` (the ADR-0016 §2 convention,
  now asserted by the publish conformance suite), and default to
  **dry-run** — deploys are destructive.
- `StageWebDirectoryStep` — staged directory-artifact resolution
  (typed override → state → `<project>/build/web`), mirroring the
  file-artifact staging precedence of the ADR-0014 targets.

## 0.1.0

- Initial release (ADR-0016 W0): typed web shell values
  (`WebShellSpec`, `WebIconSpec`, `PwaManifestSpec`,
  `WebShellContribution`), head/body entry types with declarative phases
  (`WebHeadPhase`: preconnect → storeSdk → app), the emitter seam
  (`ShellEmitter`, `ShellOutput`) with two first-party emitters
  (`GenerateShellEmitter` — owns `web/index.html` + `web/manifest.json`
  with generated-content banners; `InjectShellEmitter` — injects between
  `<!-- oka:begin:head -->` / `<!-- oka:end:head -->` markers, fails
  actionably when markers are absent), pipeline steps
  (`ValidateWebShellStep`, `EmitWebShellStep`, `WebZipStep`,
  `FlutterWebBuildStep`), and the `web-shell` / `web-build` targets.
