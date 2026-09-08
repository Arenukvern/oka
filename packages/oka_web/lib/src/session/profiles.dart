/// Named browser session profiles (ADR-0017 §4): first-party const spec
/// contributions — the same contribution law as ADR-0016 §3 (store shell
/// contributions): intentcall (or any package) may ship its own
/// `BrowserSessionSpec`s; oka ships the ones its own testing needs.
library;

import 'browser_session_spec.dart';

/// The two Chromium flags that expose WebMCP `modelContext` (pre-stable
/// feature), sourced verbatim from the flutter_mcp_toolkit `webmcp`
/// command (`kWebmcpChromeBrowserFlags`).
///
/// flutter_mcp_toolkit / intentcall is the **source of truth** for this
/// surface: when the feature ships stable or the flags change, the toolkit
/// changes first and this const follows. Manual fallback for a browser
/// launched by hand: `chrome://flags/#enable-webmcp-testing`.
///
/// Boundary (ADR-0017 §3, ADR-0016): oka owns the *configuration value*
/// only — the WebMCP protocol, `modelContext` negotiation, and any CDP
/// client logic live in the toolkit, never in oka.
const List<String> chromeWebMcpFlags = <String>[
  '--enable-features=WebModelContext',
  '--enable-experimental-web-platform-features',
];

/// A [BrowserSessionSpec] carrying exactly the [chromeWebMcpFlags] — the
/// pre-stable WebMCP posture for Chrome sessions (agent / E2E testing).
///
/// ```dart
/// ChromeSessionTarget(
///   spec: chromeWebMcp(binaryPath: '/usr/bin/google-chrome'),
/// )
/// ```
///
/// Dartdoc contract: flags sourced from the flutter_mcp_toolkit `webmcp`
/// command (pre-stable `WebModelContext`; manual fallback
/// `chrome://flags/#enable-webmcp-testing`). WebMCP protocol logic lives in
/// the toolkit, not oka (ADR-0017 §3).
///
/// [binaryPath] is required (no provisioning default — ADR-0017 S1);
/// everything else keeps [BrowserSessionSpec] defaults (headless, ephemeral
/// profile, auto-assigned CDP port) unless overridden.
BrowserSessionSpec chromeWebMcp({
  required final String binaryPath,
  final int? debugPort,
  final bool headless = true,
  final ProfilePersistence profilePersistence = ProfilePersistence.ephemeral,
  final Duration bootTimeout = const Duration(seconds: 30),
  final ({int width, int height})? windowSize,
}) =>
    BrowserSessionSpec(
      binaryPath: binaryPath,
      launchFlags: chromeWebMcpFlags,
      debugPort: debugPort,
      headless: headless,
      profilePersistence: profilePersistence,
      bootTimeout: bootTimeout,
      windowSize: windowSize,
    );
