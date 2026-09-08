// ADR-0016 W0 — pure validation (shellIssues) + icon existence checks.
import 'dart:io';

import 'package:oka_web/oka_web.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('base-href format', () {
    test('accepts "/", "/app/", "/a/b/"', () {
      expect(isValidBaseHref('/'), isTrue);
      expect(isValidBaseHref('/app/'), isTrue);
      expect(isValidBaseHref('/a/b/'), isTrue);
    });

    test('rejects missing leading/trailing slash and empty segments', () {
      expect(isValidBaseHref('app/'), isFalse);
      expect(isValidBaseHref('/app'), isFalse);
      expect(isValidBaseHref('//'), isFalse);
      expect(isValidBaseHref('/a//b/'), isFalse);
    });

    test('shellIssues reports an invalid base href actionably', () {
      final issues = shellIssues(
        const WebShell(spec: WebShellSpec(title: 'X', baseHref: 'app')),
      );
      expect(
        issues.join('\n'),
        contains('invalid base href "app"'),
      );
    });
  });

  group('identity / name patterns', () {
    test('empty title is an issue naming the fix', () {
      final issues =
          shellIssues(const WebShell(spec: const WebShellSpec()));
      expect(issues.join('\n'), contains('shell title is empty'));
      expect(issues.join('\n'), contains('WebShellSpec.title'));
    });
  });

  group('duplicate entries', () {
    test('duplicate link rel+href is reported', () {
      const dup = SimpleWebShellContribution(
        head: [
          WebLinkEntry(rel: 'icon', href: 'a.png'),
          WebLinkEntry(rel: 'icon', href: 'a.png'),
        ],
      );
      final issues = shellIssues(
        WebShell(spec: const WebShellSpec(title: 'X'), contributions: const [dup]),
      );
      expect(issues.join('\n'), contains('duplicate head entry link:'));
    });

    test('duplicate meta name is reported', () {
      const dup = SimpleWebShellContribution(
        head: [
          WebMetaEntry(name: 'theme-color', content: '#000'),
          WebMetaEntry(name: 'theme-color', content: '#fff'),
        ],
      );
      final issues = shellIssues(
        WebShell(spec: const WebShellSpec(title: 'X'), contributions: const [dup]),
      );
      expect(issues.join('\n'), contains('duplicate head entry meta:'));
    });

    test('distinct entries with same href are fine', () {
      const ok = SimpleWebShellContribution(
        head: [
          WebLinkEntry(rel: 'icon', href: 'a.png'),
          WebLinkEntry(rel: 'apple-touch-icon', href: 'a.png'),
        ],
      );
      expect(
        shellIssues(
          WebShell(
            spec: const WebShellSpec(title: 'X'),
            contributions: const [ok],
          ),
        ),
        isEmpty,
      );
    });
  });

  group('phase sanity', () {
    test('composed head is always phase-ordered (guard holds)', () {
      const shell = WebShell(
        spec: WebShellSpec(
          title: 'X',
          metaEntries: [WebMetaEntry(name: 'a')],
        ),
        contributions: [
          SimpleWebShellContribution(
            head: [
              WebScriptEntry(src: 's.js', phase: WebHeadPhase.storeSdk),
              WebLinkEntry(
                rel: 'preconnect',
                href: 'https://x.example',
                phase: WebHeadPhase.preconnect,
              ),
            ],
          ),
        ],
      );
      expect(shellIssues(shell), isEmpty);
      expect(
        shell.head.map((final e) => e.phase.order),
        [WebHeadPhase.preconnect.order, WebHeadPhase.storeSdk.order,
         WebHeadPhase.app.order],
      );
    });
  });

  group('icon existence', () {
    late Directory temp;
    setUp(() {
      temp = Directory.systemTemp.createTempSync('oka_web_icons_');
      Directory(p.join(temp.path, 'web', 'icons'))
          .createSync(recursive: true);
      File(p.join(temp.path, 'web', 'icons', 'Icon-192.png'))
          .writeAsBytesSync([0x89, 0x50]);
    });
    tearDown(() => temp.deleteSync(recursive: true));

    test('declared-but-missing icons are reported with the fix', () {
      final shell = WebShell(
        spec: const WebShellSpec(
          title: 'X',
          icons: WebIconSpec(
            icon192: 'icons/Icon-192.png',
            icon512: 'icons/Icon-512.png',
          ),
        ),
      );
      final issues = iconIssues(
        shell,
        webDir: p.join(temp.path, 'web'),
      );
      expect(issues, hasLength(1));
      expect(
        issues.join('\n'),
        allOf(
          contains('icons/Icon-512.png'),
          contains('does not exist'),
          contains('WebIconSpec declares existing PNG paths'),
        ),
      );
    });

    test('existing icons pass', () {
      final shell = WebShell(
        spec: const WebShellSpec(
          title: 'X',
          icons: const WebIconSpec(icon192: 'icons/Icon-192.png'),
        ),
      );
      expect(
        validateWebShell(shell, webDir: p.join(temp.path, 'web')),
        isEmpty,
      );
    });
  });
}
