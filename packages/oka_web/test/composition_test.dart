// ADR-0016 W0 — composition ordering and override semantics.
import 'package:oka_web/oka_web.dart';
import 'package:test/test.dart';

void main() {
  group('phase ordering', () {
    test('preconnect < storeSdk < app, declaration order within a phase',
        () {
      const contribution = SimpleWebShellContribution(
        head: [
          // Declared out of phase order on purpose.
          WebMetaEntry(name: 'app-meta', phase: WebHeadPhase.app),
          WebScriptEntry(
            src: 'https://store.example/sdk.js',
            phase: WebHeadPhase.storeSdk,
          ),
          WebLinkEntry(
            rel: 'preconnect',
            href: 'https://cdn.example.com',
            phase: WebHeadPhase.preconnect,
          ),
          WebLinkEntry(
            rel: 'preconnect',
            href: 'https://other.example.com',
            phase: WebHeadPhase.preconnect,
          ),
          WebScriptEntry(
            src: 'https://app.example/glue.js',
            phase: WebHeadPhase.app,
            async: true,
          ),
        ],
      );
      final head = WebShell(
        spec: const WebShellSpec(title: 'X'),
        contributions: const [contribution],
      ).head;
      expect(
        head.map((final e) => e.phase).toList(),
        [
          WebHeadPhase.preconnect,
          WebHeadPhase.preconnect,
          WebHeadPhase.storeSdk,
          WebHeadPhase.app,
          WebHeadPhase.app,
        ],
      );
      // Within a phase: declaration order preserved (stable sort).
      final preconnects =
          head.whereType<WebLinkEntry>().toList();
      expect(preconnects[0].href, 'https://cdn.example.com');
      expect(preconnects[1].href, 'https://other.example.com');
    });

    test('spec entries participate in the same phase ordering', () {
      const spec = WebShellSpec(
        title: 'X',
        metaEntries: [WebMetaEntry(name: 'viewport', content: 'width')],
      );
      const store = SimpleWebShellContribution(
        head: [
          WebLinkEntry(
            rel: 'preconnect',
            href: 'https://cdn.example.com',
            phase: WebHeadPhase.preconnect,
          ),
        ],
      );
      final head =
          WebShell(spec: spec, contributions: const [store]).head;
      // preconnect first, then spec's app-phase meta.
      expect(head[0].phase, WebHeadPhase.preconnect);
      expect(head[1], isA<WebMetaEntry>());
    });

    test('multiple contributions: declaration order across them', () {
      const first = SimpleWebShellContribution(
        head: [
          WebScriptEntry(src: 'https://a.example/sdk.js',
              phase: WebHeadPhase.storeSdk),
        ],
      );
      const second = SimpleWebShellContribution(
        head: [
          WebScriptEntry(src: 'https://b.example/sdk.js',
              phase: WebHeadPhase.storeSdk),
        ],
      );
      final head = WebShell(
        spec: const WebShellSpec(title: 'X'),
        contributions: const [first, second],
      ).head;
      expect(
        head.whereType<WebScriptEntry>().map((final e) => e.src),
        ['https://a.example/sdk.js', 'https://b.example/sdk.js'],
      );
    });
  });

  group('base href overrides', () {
    test('last contribution override wins over the spec', () {
      const spec = WebShellSpec(title: 'X', baseHref: '/app/');
      const a = SimpleWebShellContribution(baseHref: '/store-a/');
      const b = SimpleWebShellContribution(baseHref: '/store-b/');
      final shell =
          WebShell(spec: spec, contributions: const [a, b]);
      expect(shell.baseHref, '/store-b/');
    });

    test('no override → spec base href', () {
      const spec = WebShellSpec(title: 'X', baseHref: '/app/');
      expect(
        WebShell(spec: spec, contributions: const []).baseHref,
        '/app/',
      );
    });
  });

  group('dart-define overrides', () {
    test('later contributions win; all defines merge', () {
      const a = SimpleWebShellContribution(
        dartDefines: {'STORE': 'ya', 'SHARED': 'a'},
      );
      const b = SimpleWebShellContribution(
        dartDefines: {'SHARED': 'b'},
      );
      expect(
        WebShell(spec: const WebShellSpec(title: 'X'), contributions: const [a, b])
            .contributionDartDefines,
        {'STORE': 'ya', 'SHARED': 'b'},
      );
    });
  });

  group('body entries', () {
    test('declaration order across contributions', () {
      const a = SimpleWebShellContribution(
        body: [WebElementEntry(tag: 'div', id: 'loading')],
      );
      const b = SimpleWebShellContribution(
        body: [WebHtmlEntry('<noscript>js off</noscript>')],
      );
      final body = WebShell(
        spec: const WebShellSpec(title: 'X'),
        contributions: const [a, b],
      ).body;
      expect(body, hasLength(2));
      expect(body[0], isA<WebElementEntry>());
      expect(body[1], isA<WebHtmlEntry>());
    });
  });

  test('describeLines includes shell identity and entry phases', () {
    const shell = WebShell(
      spec: WebShellSpec(title: 'X'),
      contributions: [
        SimpleWebShellContribution(
          head: [
            WebLinkEntry(
              rel: 'preconnect',
              href: 'https://cdn.example.com',
              phase: WebHeadPhase.preconnect,
            ),
            WebScriptEntry(src: 'https://store.example/sdk.js',
                phase: WebHeadPhase.storeSdk),
          ],
          body: [WebElementEntry(tag: 'div', id: 'loading')],
        ),
      ],
    );
    final lines = shell.describeLines();
    expect(lines.any((final l) => l.contains('shell: "X"')), isTrue);
    expect(lines.any((final l) => l.contains('preconnect: 1')), isTrue);
    expect(lines.any((final l) => l.contains('storeSdk: 1')), isTrue);
    expect(lines.any((final l) => l.contains('body entries: 1')), isTrue);
    expect(
      lines.any((final l) => l.contains('preconnect — WebLinkEntry')),
      isTrue,
    );
  });
}
