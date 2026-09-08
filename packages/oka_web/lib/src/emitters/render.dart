/// Shared rendering helpers for shell emitters (ADR-0016).
///
/// Pure string builders — no I/O — unit-tested for exact output.
library;

import '../spec/body_entry.dart';
import '../spec/head_entry.dart';

/// HTML-escapes an attribute value (`&`, `"`, `<`, `>`).
String escapeAttribute(final String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// HTML-escapes text content (`&`, `<`, `>`).
String escapeText(final String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// Renders one [WebHeadEntry] as a single HTML line, indented two spaces.
String renderHeadEntry(final WebHeadEntry entry) {
  final buffer = StringBuffer('  ');
  switch (entry) {
    case final WebMetaEntry e:
      if (e.charset != null) {
        buffer.write('<meta charset="${escapeAttribute(e.charset!)}">');
      } else if (e.name != null) {
        buffer.write(
          '<meta name="${escapeAttribute(e.name!)}" '
          'content="${escapeAttribute(e.content)}">',
        );
      } else if (e.property != null) {
        buffer.write(
          '<meta property="${escapeAttribute(e.property!)}" '
          'content="${escapeAttribute(e.content)}">',
        );
      } else if (e.httpEquiv != null) {
        buffer.write(
          '<meta http-equiv="${escapeAttribute(e.httpEquiv!)}" '
          'content="${escapeAttribute(e.content)}">',
        );
      }
    case final WebLinkEntry e:
      buffer.write('<link rel="${escapeAttribute(e.rel)}" '
          'href="${escapeAttribute(e.href)}"');
      if (e.sizes != null) {
        buffer.write(' sizes="${escapeAttribute(e.sizes!)}"');
      }
      if (e.type != null) buffer.write(' type="${escapeAttribute(e.type!)}"');
      if (e.crossOrigin != null) {
        buffer.write(' crossorigin="${escapeAttribute(e.crossOrigin!)}"');
      }
      buffer.write('>');
    case final WebScriptEntry e:
      final mode = <String>[
        if (e.async) 'async',
        if (e.defer) 'defer',
      ];
      if (e.src != null) {
        buffer.write('<script ');
        if (e.type != null) {
          buffer.write('type="${escapeAttribute(e.type!)}" ');
        }
        buffer.write('src="${escapeAttribute(e.src!)}"');
        if (mode.isNotEmpty) buffer.write(' ${mode.join(' ')}');
        buffer.write('></script>');
      } else {
        buffer.write('<script');
        if (e.type != null) {
          buffer.write(' type="${escapeAttribute(e.type!)}"');
        }
        buffer
          ..write('>')
          ..write(e.content ?? '')
          ..write('</script>');
      }
  }
  return buffer.toString();
}

/// Renders one [WebBodyEntry] as an indented HTML line (or lines).
List<String> renderBodyEntry(final WebBodyEntry entry) => switch (entry) {
      final WebHtmlEntry e => e.html
          .split('\n')
          .map((final line) => '  $line')
          .toList(),
      final WebElementEntry e => [
          '  <${_openTag(e)}>${escapeText(e.text)}</${e.tag}>',
        ],
    };

String _openTag(final WebElementEntry e) {
  final buffer = StringBuffer(e.tag);
  if (e.id != null) buffer.write(' id="${escapeAttribute(e.id!)}"');
  if (e.classes.isNotEmpty) {
    buffer.write(' class="${escapeAttribute(e.classes.join(' '))}"');
  }
  for (final attr in e.attributes.entries) {
    buffer.write(
      ' ${escapeAttribute(attr.key)}="${escapeAttribute(attr.value)}"',
    );
  }
  return buffer.toString();
}
