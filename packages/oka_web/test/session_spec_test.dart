// ADR-0017 S0 — BrowserSessionSpec validation (fail-closed per ADR-0017
// §3) and the chromeWebMcp profile (exactly the two WebMCP flags, sourced
// from the flutter_mcp_toolkit webmcp command).
import 'package:oka_web/oka_web.dart';
import 'package:test/test.dart';

void main() {
  group('BrowserSessionSpec', () {
    test('defaults follow the test/agent posture (ADR-0017 §1, §5)', () {
      const spec = BrowserSessionSpec(binaryPath: '/usr/bin/google-chrome');
      expect(spec.launchFlags, isEmpty);
      expect(spec.debugPort, isNull); // auto-assign
      expect(spec.headless, isTrue);
      expect(spec.profilePersistence, ProfilePersistence.ephemeral);
      expect(spec.debugProtocol, DebugProtocol.cdp);
      expect(spec.bootTimeout, const Duration(seconds: 30));
      expect(spec.windowSize, isNull);
      expect(spec.validate(), isEmpty);
    });

    test('empty binaryPath is rejected (provisioning deferred, S1)', () {
      const spec = BrowserSessionSpec(binaryPath: '  ');
      expect(spec.validate(), hasLength(1));
      expect(
        spec.validate().single,
        contains('binaryPath is empty'),
      );
    });

    test('out-of-range debugPort is rejected', () {
      const negative = BrowserSessionSpec(
        binaryPath: 'chrome',
        debugPort: -1,
      );
      const tooHigh = BrowserSessionSpec(binaryPath: 'chrome', debugPort: 65536);
      expect(negative.validate().join(' '), contains('not a valid TCP port'));
      expect(tooHigh.validate().join(' '), contains('not a valid TCP port'));
      expect(
        const BrowserSessionSpec(binaryPath: 'chrome', debugPort: 0)
            .validate(),
        isEmpty,
      );
    });

    test('non-positive bootTimeout is rejected', () {
      const spec = BrowserSessionSpec(
        binaryPath: 'chrome',
        bootTimeout: Duration.zero,
      );
      expect(spec.validate().join(' '), contains('bootTimeout must be positive'));
    });

    test('non-positive windowSize dimensions are rejected', () {
      const spec = BrowserSessionSpec(
        binaryPath: 'chrome',
        windowSize: (width: 0, height: 600),
      );
      expect(spec.validate().join(' '), contains('windowSize'));
      expect(
        const BrowserSessionSpec(
          binaryPath: 'chrome',
          windowSize: (width: 800, height: 600),
        ).validate(),
        isEmpty,
      );
    });

    test('oka-owned flags fail closed, naming the typed surface '
        '(ADR-0017 §3)', () {
      for (final flag in const [
        '--remote-debugging-port=9222',
        '--user-data-dir=/tmp/x',
        '--headless',
        '--window-size=800x600',
        '--no-first-run',
        '--no-default-browser-check',
      ]) {
        final spec = BrowserSessionSpec(
          binaryPath: 'chrome',
          launchFlags: [flag],
        );
        final issues = spec.validate();
        expect(issues, hasLength(1), reason: flag);
        expect(issues.single, contains('collides with the oka-owned flag'));
        expect(issues.single, contains('Use the typed spec surface'));
      }
    });

    test('unrelated user flags pass validation', () {
      const spec = BrowserSessionSpec(
        binaryPath: 'chrome',
        launchFlags: ['--enable-features=WebModelContext', '--lang=de'],
      );
      expect(spec.validate(), isEmpty);
    });
  });

  group('chromeWebMcp profile', () {
    test('carries exactly the two WebMCP flags', () {
      final spec = chromeWebMcp(binaryPath: '/usr/bin/google-chrome');
      expect(spec.launchFlags, [
        '--enable-features=WebModelContext',
        '--enable-experimental-web-platform-features',
      ]);
      expect(spec.validate(), isEmpty);
    });

    test('keeps the agent-posture defaults; overrides flow through', () {
      final spec = chromeWebMcp(
        binaryPath: 'chrome',
        debugPort: 9222,
        headless: false,
        profilePersistence: ProfilePersistence.persistent,
      );
      expect(spec.debugPort, 9222);
      expect(spec.headless, isFalse);
      expect(spec.profilePersistence, ProfilePersistence.persistent);
      expect(spec.launchFlags, chromeWebMcpFlags);
    });

    test('flags are a const, shared list (third-party contribution '
        'surface, ADR-0017 §4)', () {
      expect(chromeWebMcpFlags, isList);
      expect(
        identical(chromeWebMcp(binaryPath: 'a').launchFlags,
            chromeWebMcp(binaryPath: 'b').launchFlags),
        isTrue,
      );
    });
  });
}
