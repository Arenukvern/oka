/// The inject emitter (ADR-0016 §1.2): first-party day one — the migration
/// path for hand-maintained `web/index.html` files.
///
/// Injects composed entries between explicit markers
/// (`<!-- oka:begin:head -->` … `<!-- oka:end:head -->`, body
/// equivalents). When markers are missing, it **fails with an actionable
/// error** naming exactly how to add them; it never rewrites unowned
/// regions — everything outside the markers is preserved byte-for-byte.
library;

import 'package:meta/meta.dart';

import '../composition.dart';
import '../emitter.dart';
import 'render.dart';

/// Head injection markers.
const String headBeginMarker = '<!-- oka:begin:head -->';
const String headEndMarker = '<!-- oka:end:head -->';

/// Body injection markers.
const String bodyBeginMarker = '<!-- oka:begin:body -->';
const String bodyEndMarker = '<!-- oka:end:body -->';

/// The inject emitter: injects composed entries into an existing,
/// hand-maintained `index.html` between explicit oka markers.
///
/// Owns only `index.html` — and only the marker-delimited regions inside
/// it. `manifest.json` is NOT owned: the project's hand-maintained file
/// remains the source of truth for everything outside the markers.
@immutable
class InjectShellEmitter extends ShellEmitter {
  const InjectShellEmitter();

  @override
  String get name => 'inject';

  @override
  Set<String> get ownedPaths => const {'index.html'};

  @override
  ShellOutput emit(
    final WebShell shell, {
    final String? existingIndexHtml,
  }) {
    if (existingIndexHtml == null) {
      throw const ShellInjectionException(
        'index.html not found. The `inject` emitter injects into an '
        'existing, hand-maintained web/index.html and never creates one. '
        'Either create web/index.html with the oka markers (see below) or '
        'use the `generate` emitter, which owns the whole file.\n'
        '\n'
        'Add the markers around your head and body injection points:\n'
        '\n'
        '```html\n'
        '<head>\n'
        '  ...your hand-maintained tags...\n'
        '  <!-- oka:begin:head -->\n'
        '  <!-- oka:end:head -->\n'
        '</head>\n'
        '<body>\n'
        '  <!-- oka:begin:body -->\n'
        '  <!-- oka:end:body -->\n'
        '</body>\n'
        '```\n'
        '\n'
        'Then re-run. The `inject` emitter never rewrites regions outside '
        'the markers.',
      );
    }

    final notes = <String>[];
    var html = _injectRegion(
      html: existingIndexHtml,
      beginMarker: headBeginMarker,
      endMarker: headEndMarker,
      content: _renderHeadBlock(shell),
      region: 'head',
      notes: notes,
    );

    if (shell.body.isNotEmpty) {
      html = _injectRegion(
        html: html,
        beginMarker: bodyBeginMarker,
        endMarker: bodyEndMarker,
        content: _renderBodyBlock(shell),
        region: 'body',
        notes: notes,
      );
    } else {
      notes.add('inject: no body entries — body region left untouched');
    }

    return ShellOutput(
      files: {'index.html': html},
      notes: notes,
    );
  }

  String _renderHeadBlock(final WebShell shell) => [
        for (final entry in shell.head) renderHeadEntry(entry),
      ].join('\n');

  String _renderBodyBlock(final WebShell shell) => [
        for (final entry in shell.body) ...renderBodyEntry(entry),
      ].join('\n');

  /// Replaces the region between [beginMarker] and [endMarker] with
  /// [content], preserving everything else byte-for-byte. Throws an
  /// actionable [ShellInjectionException] when markers are missing or
  /// unbalanced.
  String _injectRegion({
    required final String html,
    required final String beginMarker,
    required final String endMarker,
    required final String content,
    required final String region,
    required final List<String> notes,
  }) {
    final hasBegin = html.contains(beginMarker);
    final hasEnd = html.contains(endMarker);
    if (!hasBegin && !hasEnd) {
      throw ShellInjectionException(_missingMarkersMessage(region));
    }
    if (hasBegin != hasEnd) {
      throw ShellInjectionException(
        'index.html has an unbalanced $region marker pair: '
        '${hasBegin ? beginMarker : endMarker} found but '
        '${hasBegin ? endMarker : beginMarker} missing.\n'
        'Add the missing marker so the pair wraps the region the web '
        'shell may manage, e.g.:\n'
        '\n'
        '  ${region == 'head' ? '<head>' : '<body>'}\n'
        '    ...\n'
        '    $beginMarker\n'
        '    ...oka-managed entries live here...\n'
        '    $endMarker\n'
        '  ${region == 'head' ? '</head>' : '</body>'}',
      );
    }
    final beginIndex = html.indexOf(beginMarker);
    final endIndex = html.indexOf(endMarker);
    if (endIndex < beginIndex) {
      throw ShellInjectionException(
        'index.html $region markers are inverted: $endMarker appears '
        'BEFORE $beginMarker. Reorder them so $beginMarker comes first '
        'and $endMarker closes the region.',
      );
    }
    notes.add(
      'inject: $region region rewritten between markers '
      '(${endIndex - beginIndex + endMarker.length} bytes → '
      '${content.length} bytes); everything else preserved byte-for-byte',
    );
    return html.replaceRange(
      beginIndex,
      endIndex + endMarker.length,
      '$beginMarker\n$content\n$endMarker',
    );
  }
}

String _missingMarkersMessage(final String region) {
  final isHead = region == 'head';
  return 'index.html has no $region markers '
      '(${isHead ? headBeginMarker : bodyBeginMarker} / '
      '${isHead ? headEndMarker : bodyEndMarker}).\n'
      'Add them around the region the web shell may manage, e.g.:\n'
      '\n'
      '  ${isHead ? '<head>' : '<body>'}\n'
      '    ...your hand-maintained tags...\n'
      '    ${isHead ? headBeginMarker : bodyBeginMarker}\n'
      '    ${isHead ? headEndMarker : bodyEndMarker}\n'
      '  ${isHead ? '</head>' : '</body>'}\n'
      '\n'
      'Then re-run. The `inject` emitter never rewrites regions outside '
      'the markers — it would silently erase your customizations '
      'otherwise.';
}
