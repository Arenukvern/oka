# 0003 — Vector-first adaptive launcher icons (no PNG tooling)

- **Status:** accepted
- **Date:** 2026-08-24
- **Decision-makers:** Anton, oka agent

## Context

Generated APKs had no `android:icon` at all (`aapt2 dump badging` reported
`icon=''`) and zero icon resources — launchers showed the default system icon.
`generateLauncherIconXml()` existed in `host_codegen.dart` but was dead code.
Android 8.0+ (API 26) uses adaptive icons; two supply formats exist:
VectorDrawable XML (sharp at any size, no tooling) and raster PNG/WebP density
buckets (universal legacy support, requires image encoding/resizing).

## Considered options

- **A. Vector-first adaptive icons** — pure XML resource set, optional
  user-supplied foreground/monochrome vectors; no binary dependencies.
- **B. Raster generation** — resize a source PNG into mipmap density buckets;
  requires an image codec dependency (e.g. `image` package).
- **C. Both from day one** — maximum compatibility, new dependency + more
  surface area before validating demand.

## Decision

Chosen option: **A**, because adaptive icons cover API 26+ (~98% of active
devices) with pure XML — preserving oka's zero-dependency packaging path
(ADR 0001 spirit). Raster `png:` remains an opt-in future extension.

1. `IconConfig` parsed from `oka.yaml` → `android.icon`
   (`background_color`, `vector`, `monochrome`).
2. `stageLauncherIcons()` in `lib/src/build/launcher_icon.dart` writes:
   `mipmap-anydpi-v26/ic_launcher.xml`, `drawable/ic_launcher_foreground.xml`
   (user vector or default oka glyph), `values/ic_launcher_background.xml`,
   optionally `drawable/ic_launcher_monochrome.xml`.
3. Manifest emits `android:icon="@mipmap/ic_launcher"` when resources staged.
4. Invalid colors / missing sources fail the host-codegen step loudly.

## Consequences

Good:
- Every oka build gets a real launcher icon with zero image tooling
- Custom branding is one YAML entry + one XML file away
- Themed-icon (monochrome) support for Android 13+

Bad / Neutral:
- Pre-API-26 devices get no icon until the raster path exists
- Users must author VectorDrawable XML for custom glyphs (no SVG conversion)

**Authoritative source:** `lib/src/build/launcher_icon.dart`,
`test/launcher_icon_test.dart`, [build guide](../guides/build_and_config.md) → Assets & Icon Station
