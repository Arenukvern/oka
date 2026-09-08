/// Typed, immutable body-entry values (ADR-0016).
///
/// Body entries describe raw containers/elements the shell injects into
/// `<body>` — loading containers, noscript blocks. No JS execution logic
/// lives here: a body entry is markup, never behavior.
library;

import 'package:meta/meta.dart';

/// One declarative `<body>` element.
@immutable
sealed class WebBodyEntry {
  const WebBodyEntry();
}

/// A raw HTML snippet, rendered verbatim into `<body>`.
///
/// Use for elements oka has no typed variant for (e.g. a store's
/// `<noscript>` block). Typed variants ([WebElementEntry]) are preferred —
/// raw snippets bypass duplicate detection.
@immutable
class WebHtmlEntry extends WebBodyEntry {
  const WebHtmlEntry(this.html);

  /// Raw HTML, inserted as-is.
  final String html;

  @override
  String toString() => 'WebHtmlEntry(${html.length} chars)';
}

/// A typed element: tag, id, classes, attributes, and text content.
@immutable
class WebElementEntry extends WebBodyEntry {
  const WebElementEntry({
    required this.tag,
    this.id,
    this.classes = const [],
    this.attributes = const {},
    this.text = '',
  });

  /// Element tag name (e.g. `div`).
  final String tag;

  /// Optional `id` attribute.
  final String? id;

  /// `class` attribute tokens.
  final List<String> classes;

  /// Additional attributes (values are HTML-escaped when rendered).
  final Map<String, String> attributes;

  /// Text content (HTML-escaped when rendered).
  final String text;

  /// Stable identity key for duplicate detection.
  String get identityKey => '$tag#${id ?? ''}';

  @override
  String toString() => 'WebElementEntry($identityKey)';
}
