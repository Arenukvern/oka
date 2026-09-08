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
merging, ADR-0010).
