// ADR-0016 W0 — InjectShellEmitter tests.
//
// Pinpoint tests: exact injected output, byte-for-byte preservation
// outside the markers, and actionable failure messages when markers are
// missing/unbalanced.
import 'package:oka_web/oka_web.dart';
import 'package:test/test.dart';

const _shell = WebShell(
  spec: WebShellSpec(title: 'Legacy', description: 'legacy app'),
  contributions: [
    SimpleWebShellContribution(
      head: [
        WebLinkEntry(
          rel: 'preconnect',
          href: 'https://sdk.example.com',
          phase: WebHeadPhase.preconnect,
        ),
        WebScriptEntry(
          src: 'https://store.example/sdk.js',
          phase: WebHeadPhase.storeSdk,
        ),
      ],
      body: [WebHtmlEntry('<noscript>enable JS</noscript>')],
    ),
  ],
);

/// The hand-maintained file shape the inject emitter exists for.
const _legacyHtml = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>Legacy</title>
  <!-- oka:begin:head -->
  <!-- oka:end:head -->
</head>
<body>
  <div id="flutter_app"></div>
  <!-- oka:begin:body -->
  <!-- oka:end:body -->
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
''';

void main() {
  test('injects entries between the head markers, preserving the rest', () {
    final output =
        const InjectShellEmitter().emit(_shell, existingIndexHtml: _legacyHtml);
    expect(output.files.keys, ['index.html']);
    expect(output.files['index.html'], '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>Legacy</title>
  <!-- oka:begin:head -->
  <link rel="preconnect" href="https://sdk.example.com">
  <script src="https://store.example/sdk.js"></script>
  <!-- oka:end:head -->
</head>
<body>
  <div id="flutter_app"></div>
  <!-- oka:begin:body -->
  <noscript>enable JS</noscript>
  <!-- oka:end:body -->
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
''');
  });

  test('preserves unowned regions byte-for-byte', () {
    final before = _legacyHtml;
    final after = const InjectShellEmitter()
        .emit(_shell, existingIndexHtml: before)
        .files['index.html']!;
    // Everything before the head begin marker.
    final prefix =
        before.substring(0, before.indexOf(headBeginMarker));
    expect(after.startsWith(prefix), isTrue);
    // Everything after the body end marker.
    final suffix =
        before.substring(before.indexOf(bodyEndMarker) + bodyEndMarker.length);
    expect(after.endsWith(suffix), isTrue);
  });

  test('no body entries → body region untouched byte-for-byte', () {
    const shell = WebShell(
      spec: WebShellSpec(title: 'Legacy'),
      contributions: [
        SimpleWebShellContribution(
          head: [WebScriptEntry(src: 'https://store.example/sdk.js')],
        ),
      ],
    );
    final output =
        const InjectShellEmitter().emit(shell, existingIndexHtml: _legacyHtml);
    expect(
      output.notes.any((final n) => n.contains('body region left untouched')),
      isTrue,
    );
    final beforeBody = _legacyHtml
        .substring(_legacyHtml.indexOf(bodyBeginMarker));
    final afterBody = output
        .files['index.html']!
        .substring(output.files['index.html']!.indexOf(bodyBeginMarker));
    expect(afterBody, beforeBody);
  });

  test('missing file → actionable failure naming the markers', () {
    const ShellInjectionException exception = ShellInjectionException('');
    expect(exception, isA<ShellInjectionException>());
    expect(
      () => const InjectShellEmitter().emit(_shell),
      throwsA(
        isA<ShellInjectionException>().having(
          (final e) => e.message,
          'message',
          allOf(
            contains('index.html not found'),
            contains('never creates one'),
            contains('use the `generate` emitter'),
            contains('<!-- oka:begin:head -->'),
            contains('<!-- oka:end:head -->'),
            contains('<!-- oka:begin:body -->'),
            contains('<!-- oka:end:body -->'),
            contains('never rewrites regions outside the markers'),
          ),
        ),
      ),
    );
  });

  test('missing head markers → actionable failure naming how to add them',
      () {
    const withoutHeadMarkers = '''
<html>
<head>
  <title>Legacy</title>
</head>
<body>
  <!-- oka:begin:body -->
  <!-- oka:end:body -->
</body>
</html>
''';
    expect(
      () => const InjectShellEmitter()
          .emit(_shell, existingIndexHtml: withoutHeadMarkers),
      throwsA(
        isA<ShellInjectionException>().having(
          (final e) => e.message,
          'message',
          allOf(
            contains('no head markers'),
            contains('<!-- oka:begin:head -->'),
            contains('<!-- oka:end:head -->'),
            contains('<head>'),
            contains('</head>'),
          ),
        ),
      ),
    );
  });

  test('missing body markers → actionable failure (only when body exists)',
      () {
    const withoutBodyMarkers = '''
<html>
<head>
  <!-- oka:begin:head -->
  <!-- oka:end:head -->
</head>
</html>
''';
    expect(
      () => const InjectShellEmitter()
          .emit(_shell, existingIndexHtml: withoutBodyMarkers),
      throwsA(
        isA<ShellInjectionException>().having(
          (final e) => e.message,
          'message',
          allOf(
            contains('no body markers'),
            contains('<!-- oka:begin:body -->'),
            contains('<!-- oka:end:body -->'),
          ),
        ),
      ),
    );
    // No body entries → body markers not required.
    const headOnly = WebShell(
      spec: WebShellSpec(title: 'Legacy'),
      contributions: [
        SimpleWebShellContribution(
          head: [WebScriptEntry(src: 'https://store.example/sdk.js')],
        ),
      ],
    );
    expect(
      () => const InjectShellEmitter()
          .emit(headOnly, existingIndexHtml: withoutBodyMarkers),
      returnsNormally,
    );
  });

  test('unbalanced markers → actionable failure naming the missing marker',
      () {
    const unbalanced = '''
<html>
<head>
  <title>Legacy</title>
  <!-- oka:begin:head -->
</head>
</html>
''';
    expect(
      () => const InjectShellEmitter()
          .emit(_shell, existingIndexHtml: unbalanced),
      throwsA(
        isA<ShellInjectionException>().having(
          (final e) => e.message,
          'message',
          allOf(
            contains('unbalanced head marker pair'),
            contains('<!-- oka:end:head --> missing'),
          ),
        ),
      ),
    );
  });

  test('inverted markers → actionable failure', () {
    const inverted = '''
<html>
<head>
  <!-- oka:end:head -->
  <!-- oka:begin:head -->
</head>
</html>
''';
    expect(
      () =>
          const InjectShellEmitter().emit(_shell, existingIndexHtml: inverted),
      throwsA(
        isA<ShellInjectionException>().having(
          (final e) => e.message,
          'message',
          contains('markers are inverted'),
        ),
      ),
    );
  });

  test('ownedPaths is index.html only — manifest is NOT owned', () {
    const emitter = InjectShellEmitter();
    expect(emitter.ownedPaths, {'index.html'});
    expect(emitter.name, 'inject');
  });
}
