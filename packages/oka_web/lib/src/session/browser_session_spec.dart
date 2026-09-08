/// The browser session "what" seam (ADR-0017 §1): a typed, const-
/// constructible description of a browser session — binary, flags, debug
/// port, headless posture, profile persistence, boot timeout, window size,
/// and the declared debug protocol.
///
/// No hidden merging (ADR-0010): users compose specs explicitly in the
/// entrypoint. Oka owns the *configuration value* only — the WebMCP
/// protocol, CDP client logic, and any runtime probing beyond the
/// readiness check stay out of oka (ADR-0017 out-of-scope; ADR-0016
/// boundary).
library;

import 'package:path/path.dart' as p;

/// How the session's browser profile persists across runs (ADR-0017 §5:
/// lifecycle is a parameter, not a type hierarchy).
enum ProfilePersistence {
  /// Fresh temporary profile dir per session (test / agent posture):
  /// no cookie/login state leaks between runs, and the dir is deleted by
  /// teardown.
  ephemeral,

  /// Stable profile dir under the build directory (dev posture): logins
  /// and browser state survive the command.
  persistent;

  /// Human-readable name used in step logs.
  String get label => switch (this) {
        ephemeral => 'ephemeral',
        persistent => 'persistent',
      };
}

/// The debug protocol a browser engine speaks (ADR-0017: engines differ in
/// capability, and the difference is *declared*, not assumed).
///
/// Declared from day one so deferred engines (Servo speaks partial
/// WebDriver; Ladybird has none yet) cost only a field value, not new
/// architecture. Chrome requires [cdp]; ChromeSessionTarget fails closed
/// on any other value (ADR-0017 §3).
enum DebugProtocol {
  /// No debug protocol — a plain browser window (future engines).
  none,

  /// WebDriver (partial on Servo; future engines).
  webdriver,

  /// Chrome DevTools Protocol — what Chromium speaks. The readiness probe
  /// polls `GET /json/version` over plain HTTP; this is a readiness probe
  /// only, never a CDP client (ADR-0017 out-of-scope line).
  cdp;

  /// Human-readable name used in errors and logs.
  String get label => switch (this) {
        none => 'none',
        webdriver => 'webdriver',
        cdp => 'cdp',
      };
}

/// Chrome flags oka owns: these are derived from typed spec fields by
/// [chromeLaunchArgs] (see chrome_session_target.dart), so a raw flag in
/// [BrowserSessionSpec.launchFlags] that collides with one of them is
/// rejected — fail closed, naming the typed surface to use instead
/// (ADR-0017 §3: unknown/colliding flags fail closed with the accepted
/// surface named).
const List<String> okaOwnedChromeFlags = <String>[
  '--remote-debugging-port',
  '--user-data-dir',
  '--headless',
  '--window-size',
  '--no-first-run',
  '--no-default-browser-check',
];

/// A typed, const-constructible browser session description (ADR-0017 §1,
/// the "what" seam).
///
/// A spec is a pure value: it never spawns, probes, or touches the
/// filesystem. The "how" seam lives in the session target/launcher
/// (`ChromeSessionTarget`, ADR-0017 §1 launcher 1 `okaOwned`). Third
/// parties ship specs as const values the way store packages ship shell
/// contributions (ADR-0017 §4) — see `chromeWebMcp` in profiles.dart for
/// the first-party example.
///
/// ```dart
/// const spec = BrowserSessionSpec(
///   binaryPath: '/Applications/Google Chrome.app/Contents/MacOS/'
///       'Google Chrome',
///   launchFlags: chromeWebMcpFlags,
/// );
/// ```
class BrowserSessionSpec {
  /// Creates a session spec. All fields have safe defaults except
  /// [binaryPath] — browser binary provisioning is a deferred concern
  /// (ADR-0017 out of scope, S1), so day one consumes an explicit path or
  /// well-known install.
  const BrowserSessionSpec({
    required this.binaryPath,
    this.launchFlags = const [],
    this.debugPort,
    this.headless = true,
    this.profilePersistence = ProfilePersistence.ephemeral,
    this.bootTimeout = const Duration(seconds: 30),
    this.windowSize,
    this.debugProtocol = DebugProtocol.cdp,
  });

  /// Absolute path (or resolvable command name) of the browser binary.
  ///
  /// Explicit by design: provisioning (chrome-for-testing into the store)
  /// is deferred (ADR-0017 out of scope, S1), and a silent "whatever
  /// Chrome I find" default would make sessions non-hermetic and
  /// un-reproducible.
  final String binaryPath;

  /// Extra Chromium launch flags, appended after the oka-owned args (last
  /// flag wins in Chromium, so user flags intentionally override nothing
  /// oka sets — oka-owned flags are rejected in [validate] instead).
  ///
  /// Example first-party value: `chromeWebMcpFlags` (profiles.dart).
  final List<String> launchFlags;

  /// Fixed CDP debug port, or null = auto-assign a free ephemeral port.
  ///
  /// Explicit ports enable the idempotent reuse path (a port that already
  /// answers CDP is reused, never spawned against — EmulatorTarget
  /// semantics, ADR-0017 §1); auto-assigned ports cannot be reused because
  /// nothing is listening before spawn.
  final int? debugPort;

  /// Headless posture — `true` (default) for test / agent sessions: no
  /// window, no first-run dialogs, deterministic in CI.
  final bool headless;

  /// Profile persistence (default [ProfilePersistence.ephemeral]): test
  /// sessions get a throwaway temp profile; dev sessions a stable one
  /// (ADR-0017 §5).
  final ProfilePersistence profilePersistence;

  /// How long the readiness probe (`GET /json/version`) may poll before
  /// the session fails, naming the exact remedy.
  final Duration bootTimeout;

  /// Initial window size (`--window-size=<w>x<h>`), or null = browser
  /// default. Kept minimal on purpose — window management is not a session
  /// concern (ADR-0017 keeps the spec to the fields the launch actually
  /// needs).
  final ({int width, int height})? windowSize;

  /// The debug protocol the engine speaks (default [DebugProtocol.cdp]).
  /// Declared per ADR-0017 §3 so future engines (webdriver/none) fit the
  /// same seam; Chrome accepts only [DebugProtocol.cdp] — enforced
  /// fail-closed by the chrome session target.
  final DebugProtocol debugProtocol;

  /// Pure validation issues (empty = valid). Fail-closed per ADR-0017 §3:
  /// a mis-typed spec must fail at composition/run start with the accepted
  /// surface named, never produce a surprising browser invocation.
  ///
  /// Engine-specific rules (e.g. Chrome requires [DebugProtocol.cdp]) live
  /// with the engine target (`chromeSessionIssues`) — the spec itself is
  /// engine-agnostic.
  List<String> validate() {
    final issues = <String>[];
    if (binaryPath.trim().isEmpty) {
      issues.add(
        'binaryPath is empty — set an explicit browser binary path '
        '(browser provisioning is deferred, ADR-0017 out-of-scope/S1).',
      );
    }
    final port = debugPort;
    if (port != null && (port < 0 || port > 65535)) {
      issues.add(
        'debugPort $port is not a valid TCP port (0–65535) — or leave '
        'debugPort null to auto-assign a free port.',
      );
    }
    if (bootTimeout <= Duration.zero) {
      issues.add(
        'bootTimeout must be positive — got $bootTimeout. The readiness '
        'probe polls /json/version for this long before failing.',
      );
    }
    final size = windowSize;
    if (size != null && (size.width <= 0 || size.height <= 0)) {
      issues.add(
        'windowSize ${size.width}x${size.height} is invalid — both '
        'dimensions must be positive.',
      );
    }
    for (final flag in launchFlags) {
      final owned = okaOwnedChromeFlags.where(flag.startsWith).firstOrNull;
      if (owned != null) {
        issues.add(
          'launchFlags contains "$flag", which collides with the oka-owned '
          'flag "$owned" — fail-closed (ADR-0017 §3). Use the typed spec '
          'surface instead: debugPort, profilePersistence, headless, '
          'windowSize.',
        );
      }
    }
    return issues;
  }

  /// Debug string: browser basename, profile persistence, debug protocol,
  /// and headless marker.
  @override
  String toString() =>
      'BrowserSessionSpec(${p.basename(binaryPath)}, '
      '${profilePersistence.label}, ${debugProtocol.label}'
      '${headless ? ', headless' : ''})';
}
