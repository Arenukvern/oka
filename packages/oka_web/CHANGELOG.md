# Changelog

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
