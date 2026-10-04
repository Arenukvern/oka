# 05 — Web stores: one shell, many storefronts

The web twin of [04](../04_stores_accounts): per-store `index.html` as
typed, drift-checked Dart — no per-store branches, no hand-edited HTML.
The compile itself stays an honest delegation to `flutter build web`
([ADR-0016](../../docs/decisions/0016-web-shell-station-store-contributions.mdx)).

## What you get

- `WebShellTarget` — composes `web/index.html`: SDK scripts with declared
  ordering phases, preconnects, PWA manifest, icons. `oka explain` renders
  the composed shell **before** anything writes.
- `WebBuildTarget` — runs `flutter build web` (named delegation).
- `GhPagesDeployTarget` — pushes `build/web` to the `gh-pages` branch.
- `ItchDeployTarget` — `butler push user/game:channel` for itch.io.

All deploy targets are **dry-run by default** — deploys are destructive, so
a real push is always a deliberate `dryRun: false` flip.

## Run it

```bash
flutter pub get
flutter create . --platforms web       # one-time scaffold

oka run web-shell          # compose + emit web/index.html (typed)
oka explain --targets      # inspect every target's step chain first
oka run web-build          # flutter build web → build/web
oka run publish-gh-pages   # dry-run plan; flip dryRun: false to push
oka run publish-itch       # same — needs butler + itch account
```

## Store differences = contributions

A store SDK script or meta tag is a `WebShellContribution` — a const value
composed into the shell. Different store → different contribution list, same
app. Beyond the two targets here, store contributions (CrazyGames, Yandex
Games, …) follow the same pattern; see the
[web shell station guide](../../docs/guides/web_shell_station.mdx).

## Next

- [06 live patch](../06_live_patch) — update apps without any store
