/// The typed project shell spec and its icon/manifest value types
/// (ADR-0016).
///
/// A [WebShellSpec] is the project's declarative web shell: identity
/// (title, description), base href, colors, display/orientation, charset
/// and extra meta entries, icon declarations, and PWA manifest defaults.
/// Everything is const-constructible; icons are **declared, not
/// rasterized** — validation checks existence only (ADR-0016 §4).
library;

import 'package:meta/meta.dart';

import 'head_entry.dart';

/// Declares existing PNG icon paths per size (ADR-0016 §4).
///
/// Paths are relative to the web directory (e.g. `icons/Icon-192.png`).
/// oka does **not** generate PNGs (ADR-0003 precedent: no image tooling);
/// validation checks existence only. Empty string = not declared.
@immutable
class WebIconSpec {
  const WebIconSpec({
    this.icon192 = '',
    this.icon512 = '',
    this.maskable = '',
    this.favicon = '',
  });

  /// 192×192 icon (also used as the apple-touch-icon).
  final String icon192;

  /// 512×512 icon.
  final String icon512;

  /// Maskable 512×512 icon (`purpose: maskable` in the manifest).
  final String maskable;

  /// Favicon (linked with `rel="icon"`).
  final String favicon;

  /// All declared (non-empty) paths → declared sizes, for validation and
  /// manifest rendering.
  Map<String, String> get declared => {
        if (icon192.isNotEmpty) icon192: '192x192',
        if (icon512.isNotEmpty) icon512: '512x512',
        if (maskable.isNotEmpty) maskable: '512x512',
        if (favicon.isNotEmpty) favicon: 'any',
      };

  @override
  String toString() =>
      'WebIconSpec(192: $icon192, 512: $icon512, maskable: $maskable, '
      'favicon: $favicon)';
}

/// PWA manifest field overrides a [WebShellContribution] may apply.
///
/// Every field is nullable: null = "do not override the project spec
/// value". Pure value — no I/O, no merging beyond [apply].
@immutable
class PwaManifestOverride {
  const PwaManifestOverride({
    this.name,
    this.shortName,
    this.startUrl,
    this.display,
    this.orientation,
    this.themeColor,
    this.backgroundColor,
    this.description,
    this.icons,
    this.preferRelatedApplications,
  });

  /// Override the manifest `name`.
  final String? name;

  /// Override the manifest `short_name`.
  final String? shortName;

  /// Override the manifest `start_url`.
  final String? startUrl;

  /// Override the manifest `display` (e.g. `fullscreen` for game stores).
  final String? display;

  /// Override the manifest `orientation` (e.g. `landscape` for games).
  final String? orientation;

  /// Override the manifest `theme_color`.
  final String? themeColor;

  /// Override the manifest `background_color`.
  final String? backgroundColor;

  /// Override the manifest `description`.
  final String? description;

  /// Replace the icon set entirely (rare — stores usually reuse the app's
  /// icons).
  final WebIconSpec? icons;

  /// Override `prefer_related_applications`.
  final bool? preferRelatedApplications;

  @override
  String toString() => 'PwaManifestOverride(display: $display, '
      'orientation: $orientation)';
}

/// PWA manifest fields — the project-level defaults plus contribution
/// overrides resolved by the shell composition.
@immutable
class PwaManifestSpec {
  const PwaManifestSpec({
    this.name = '',
    this.shortName = '',
    this.startUrl = '.',
    this.display = 'standalone',
    this.orientation = 'portrait-primary',
    this.themeColor = '',
    this.backgroundColor = '',
    this.description = '',
    this.icons = const WebIconSpec(),
    this.preferRelatedApplications = false,
  });

  /// Manifest `name` (defaults to the shell title).
  final String name;

  /// Manifest `short_name` (defaults to the shell title).
  final String shortName;

  /// Manifest `start_url` (`.` by default).
  final String startUrl;

  /// Manifest `display` (`standalone` by default).
  final String display;

  /// Manifest `orientation` (`portrait-primary` by default).
  final String orientation;

  /// Manifest `theme_color`.
  final String themeColor;

  /// Manifest `background_color`.
  final String backgroundColor;

  /// Manifest `description`.
  final String description;

  /// Declared icons.
  final WebIconSpec icons;

  /// Manifest `prefer_related_applications`.
  final bool preferRelatedApplications;

  /// Applies [override] on top of these fields (null fields pass through).
  PwaManifestSpec apply(final PwaManifestOverride override) => PwaManifestSpec(
        name: override.name ?? name,
        shortName: override.shortName ?? shortName,
        startUrl: override.startUrl ?? startUrl,
        display: override.display ?? display,
        orientation: override.orientation ?? orientation,
        themeColor: override.themeColor ?? themeColor,
        backgroundColor: override.backgroundColor ?? backgroundColor,
        description: override.description ?? description,
        icons: override.icons ?? icons,
        preferRelatedApplications:
            override.preferRelatedApplications ?? preferRelatedApplications,
      );

  @override
  String toString() => 'PwaManifestSpec(name: $name, display: $display)';
}

/// The project's declarative web shell (ADR-0016 §1).
///
/// Identity + defaults; contributions (store SDKs, ads harnesses) compose
/// over it via [WebShellContribution]s in the composition root. Pure,
/// const-constructible value.
@immutable
class WebShellSpec {
  const WebShellSpec({
    this.title = '',
    this.description = '',
    this.baseHref = '/',
    this.themeColor = '',
    this.backgroundColor = '',
    this.display = 'standalone',
    this.orientation = 'portrait-primary',
    this.startUrl = '.',
    this.charset = 'UTF-8',
    this.metaEntries = const [],
    this.icons = const WebIconSpec(),
    this.manifest = const PwaManifestSpec(),
  });

  /// Document title / app name (also the manifest `name` default).
  final String title;

  /// Meta description (also the manifest `description` default).
  final String description;

  /// Base href as served, e.g. `/` or `/app/`. Must start and end with
  /// `/` (validated before any I/O).
  final String baseHref;

  /// Theme color (meta + manifest `theme_color`).
  final String themeColor;

  /// Background color (manifest `background_color`).
  final String backgroundColor;

  /// Manifest `display` (`standalone` by default).
  final String display;

  /// Manifest `orientation` (`portrait-primary` by default).
  final String orientation;

  /// Manifest `start_url` (`.` by default).
  final String startUrl;

  /// Charset meta value (`UTF-8` by default).
  final String charset;

  /// Extra meta entries rendered in the composed head (app phase).
  final List<WebMetaEntry> metaEntries;

  /// Declared icons (existence-validated, never rasterized).
  final WebIconSpec icons;

  /// PWA manifest field defaults (contribution overrides compose over it).
  final PwaManifestSpec manifest;

  @override
  String toString() => "WebShellSpec(title: '$title', baseHref: '$baseHref')";
}
