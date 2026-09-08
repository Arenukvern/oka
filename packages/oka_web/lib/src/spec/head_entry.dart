/// Typed, immutable head-entry values (ADR-0016).
///
/// A head entry is a *declarative* description of one `<head>` element:
/// `meta`, `link`, or `script`. Entries carry a [WebHeadPhase]; the shell
/// composition orders entries by phase (`preconnect` < `storeSdk` <
/// `app`), preserving declaration order within a phase. No JS execution
/// logic lives here — script contents are opaque declarative values.
library;

import 'package:meta/meta.dart';

/// Declarative ordering phase of a [WebHeadEntry].
///
/// Phases encode ordering constraints that stores document but runtime
/// loaders cannot fix (ADR-0016 context): preconnects must precede SDK
/// scripts, store SDK scripts must precede app glue.
enum WebHeadPhase {
  /// DNS/TLS preconnects and early hints — always first.
  preconnect,

  /// The store's SDK `<script>` (Yandex Games, CrazyGames, …).
  storeSdk,

  /// App-owned entries: meta, icons, analytics glue.
  app;

  /// Lower sorts earlier in the composed `<head>`.
  int get order => index;
}

/// One declarative `<head>` element.
///
/// Sealed: the only variants are [WebMetaEntry], [WebLinkEntry], and
/// [WebScriptEntry]. All are const-constructible so store packages can
/// ship const contributions.
@immutable
sealed class WebHeadEntry {
  const WebHeadEntry({this.phase = WebHeadPhase.app});

  /// Ordering phase ([WebHeadPhase.app] by default).
  final WebHeadPhase phase;

  /// Stable identity key for duplicate detection (validation).
  String get identityKey;
}

/// `<meta charset>` / `<meta name|property|http-equiv … content>` entry.
@immutable
class WebMetaEntry extends WebHeadEntry {
  const WebMetaEntry({
    this.charset,
    this.name,
    this.property,
    this.httpEquiv,
    this.content = '',
    super.phase,
  }) : assert(
          (name == null) != (property == null) ||
              (property == null) != (httpEquiv == null) ||
              charset != null,
          'exactly one of charset, name, property, or httpEquiv must be set',
        );

  /// Charset value — renders `<meta charset="UTF-8">`.
  final String? charset;

  /// `name` attribute (e.g. `theme-color`).
  final String? name;

  /// `property` attribute (OpenGraph / store-specific).
  final String? property;

  /// `http-equiv` attribute (e.g. `X-UA-Compatible`).
  final String? httpEquiv;

  /// `content` attribute (ignored for charset).
  final String content;

  /// Stable identity key for duplicate detection.
  @override
  String get identityKey => charset != null
      ? 'charset'
      : 'name=$name|property=$property|http-equiv=$httpEquiv';

  @override
  String toString() => 'WebMetaEntry($identityKey${content.isEmpty ? '' : ' content=$content'})';
}

/// `<link rel … href>` entry (preconnects, icons, manifest link, styles).
@immutable
class WebLinkEntry extends WebHeadEntry {
  const WebLinkEntry({
    required this.rel,
    required this.href,
    this.sizes,
    this.type,
    this.crossOrigin,
    super.phase,
  });

  /// `rel` attribute (e.g. `preconnect`, `icon`, `stylesheet`).
  final String rel;

  /// `href` attribute.
  final String href;

  /// Optional `sizes` attribute (icons).
  final String? sizes;

  /// Optional `type` attribute (e.g. `image/png`).
  final String? type;

  /// Optional `crossorigin` attribute (preconnects to CDN origins).
  final String? crossOrigin;

  /// Stable identity key for duplicate detection.
  @override
  String get identityKey => 'rel=$rel|href=$href';

  @override
  String toString() => 'WebLinkEntry($identityKey)';
}

/// `<script src>` / inline `<script>` entry — the store-SDK seam.
///
/// Declarative only: oka never bundles, transforms, or executes JS
/// (ADR-0016 out-of-scope). [requiredSdkGlobal] records the global the
/// script is expected to define so `oka doctor` and the shell gate (W1+)
/// can reconcile build-time declarations with runtime probing.
@immutable
class WebScriptEntry extends WebHeadEntry {
  const WebScriptEntry({
    this.src,
    this.content,
    this.type,
    this.defer = false,
    this.async = false,
    this.requiredSdkGlobal,
    super.phase,
  }) : assert(
          (src == null) != (content == null),
          'exactly one of src or content must be set',
        );

  /// External script URL. Null for inline scripts ([content] set instead).
  final String? src;

  /// Inline script body (opaque, rendered verbatim between the tags).
  final String? content;

  /// Optional `type` attribute (e.g. `module`, `application/json`).
  final String? type;

  /// Render the `defer` attribute (external scripts only).
  final bool defer;

  /// Render the `async` attribute (external scripts only).
  final bool async;

  /// Global this SDK script is expected to define (e.g. `YandexGames`).
  /// Purely declarative metadata for the doctor/gate — never executed.
  final String? requiredSdkGlobal;

  /// Stable identity key for duplicate detection.
  @override
  String get identityKey =>
      src != null ? 'src=$src' : 'inline#${content.hashCode}';

  @override
  String toString() => 'WebScriptEntry($identityKey, phase=$phase)';
}
