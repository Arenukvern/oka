/// The `chrome-session` target (ADR-0017 §3): Chrome-first browser session
/// as a composable target — the second instance of the EmulatorTarget
/// pattern (ADR-0017 Context), not a new mechanism.
///
/// What it does, per run:
///
/// 1. **Ensure session, idempotently** — if something already answers CDP
///    on the chosen port, it is *reused* (never spawned against; the same
///    semantics as EmulatorTarget reusing a running emulator). Otherwise
///    the binary is spawned with `--remote-debugging-port`, an ephemeral
///    temp profile dir (unless [BrowserSessionSpec.profilePersistence] is
///    `persistent`), and the spec's flags.
/// 2. **Readiness probe** — poll `GET http://127.0.0.1:<port>/json/version`
///    until it answers or [BrowserSessionSpec.bootTimeout] elapses. This is
///    a plain-HTTP readiness probe ONLY: no CDP client, no websocket, no
///    protocol negotiation (ADR-0017 out-of-scope line — that logic lives
///    in the toolkit).
/// 3. **Artifacts** — the session-handle convention (ADR-0017 §2):
///    `session-chrome-<name>-handle` ([String], the CDP base URL like
///    `http://127.0.0.1:9222`) and `session-chrome-<name>-cdp-port`
///    ([int]). Downstream steps consume these and never know the session
///    kind. Sub-handles `…-pid` / `…-profile-dir` support teardown.
///
/// ```dart
/// targets: [
///   ChromeSessionTarget(
///     spec: chromeWebMcp(binaryPath: '/usr/bin/google-chrome'),
///   ),
/// ]
/// ```
///
/// Teardown is an explicitly composed [StopChromeSessionStep] (the
/// StopEmulatorStep precedent) — the `Target`/step contract has no
/// automatic end-of-run hook, so ephemeral teardown is a step, not magic.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import 'browser_session_spec.dart';

// -- Artifact id convention (ADR-0017 §2) ------------------------------------

/// `session-<name>-handle`: the opaque primary handle. For Chrome the
/// value is the CDP base URL (`http://127.0.0.1:9222`) — downstream steps
/// build DevTools/HTTP endpoints on it without knowing how the session got
/// there. Frozen naming contract: renaming breaks consumers (ADR-0017
/// Consequences).
String chromeSessionHandleArtifactId(final String name) =>
    'session-chrome-$name-handle';

/// `session-<name>-cdp-port`: the engine-specific sub-handle carrying the
/// CDP port as an [int].
String chromeSessionCdpPortArtifactId(final String name) =>
    'session-chrome-$name-cdp-port';

/// `session-<name>-pid`: the spawned browser OS process id. Recorded so a
/// composed [StopChromeSessionStep] can stop exactly the process oka
/// started (and only that one).
String chromeSessionPidArtifactId(final String name) =>
    'session-chrome-$name-pid';

/// `session-<name>-profile-dir`: the ephemeral profile directory oka
/// created for this session. Recorded only for ephemeral spawns so
/// teardown deletes only dirs oka owns — never a reused session's profile,
/// never a persistent one.
String chromeSessionProfileDirArtifactId(final String name) =>
    'session-chrome-$name-profile-dir';

// -- Pure command construction (scripted-fake testable) ----------------------

/// Chromium launch args for one session — pure, golden-tested (house
/// style: `avdManagerCreateArgs`).
///
/// Oka-owned flags come first (debug port, profile dir, headless, first-run
/// suppression, window size), then [flags] verbatim — Chromium resolves
/// repeated switches last-wins, so user flags are appended *after* and can
/// therefore only ever add, never silently override, what oka sets
/// (collisions are rejected earlier, fail-closed, by
/// [BrowserSessionSpec.validate]).
List<String> chromeLaunchArgs({
  required final int debugPort,
  required final String profileDir,
  required final List<String> flags,
  required final bool headless,
  final ({int width, int height})? windowSize,
}) =>
    [
      '--remote-debugging-port=$debugPort',
      '--user-data-dir=$profileDir',
      if (headless) '--headless',
      // Automation posture: suppress first-run / default-browser prompts —
      // headful sessions must boot unattended too (agents never click
      // through dialogs).
      '--no-first-run',
      '--no-default-browser-check',
      if (windowSize != null) '--window-size=${windowSize.width}x${windowSize.height}',
      ...flags,
    ];

/// Parses a CDP `/json/version` response body, extracting the `Browser`
/// field (e.g. `Chrome/126.0.6478.126`).
///
/// Pure and total: invalid JSON, non-object JSON, or a missing/empty
/// `Browser` field all return null — the readiness probe treats null as
/// "not ready" and keeps polling. Deliberately extracts nothing else:
/// parsing deeper CDP surfaces would be the first step down the CDP-client
/// slope oka explicitly stays off (ADR-0017 out-of-scope line).
String? parseVersionJson(final String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final browser = decoded['Browser'];
  if (browser is! String || browser.isEmpty) return null;
  return browser;
}

/// Assigns a free TCP port on the loopback interface (bind to port 0, read
/// the assigned port, release).
///
/// There is an inherent bind-race (the port could be taken between release
/// and Chrome's bind) — accepted because the alternative (Chromium's
/// `--remote-debugging-port=0` + DevToolsActivePort file) would split the
/// readiness story across two mechanisms; the HTTP probe remains the single
/// readiness seam (ADR-0017 §1). Pass an explicit [BrowserSessionSpec.debugPort]
/// to avoid the race entirely.
Future<int> assignEphemeralPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// Engine-agnostic spec issues plus Chrome's capability declaration
/// (ADR-0017 §3): Chrome speaks CDP only. Pure — surfaced by
/// [EnsureChromeSessionStep] at run start and usable by `oka explain` /
/// tests without any I/O.
List<String> chromeSessionIssues(final BrowserSessionSpec spec) {
  final issues = List<String>.of(spec.validate());
  if (spec.debugProtocol != DebugProtocol.cdp) {
    issues.add(
      'chrome-session requires debugProtocol: DebugProtocol.cdp — Chrome '
          'speaks CDP only (ADR-0017 §3). Accepted surface for Chrome: '
          'cdp; webdriver/none belong to future engines (Servo/Ladybird, '
          'deferred).',
    );
  }
  return issues;
}

// -- Injectable seams --------------------------------------------------------

/// HTTP fetch seam for the readiness probe: returns the response body on
/// HTTP 200, null otherwise (connection refused, timeout, non-200).
///
/// Injectable so lifecycle tests script probe answers without sockets
/// (scripted-fake style, see EmulatorTarget's injected `runProcess`).
typedef CdpProbe = Future<String?> Function(Uri url);

/// Default [CdpProbe]: plain `dart:io` HttpClient GET. This is a readiness
/// probe only — no websocket upgrade, no CDP commands, no protocol logic
/// (ADR-0017 out-of-scope line).
Future<String?> httpCdpProbe(final Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await client.getUrl(url).timeout(const Duration(seconds: 2));
    final response = await request.close().timeout(const Duration(seconds: 2));
    if (response.statusCode != HttpStatus.ok) return null;
    return await utf8.decoder.bind(response).join();
  } on Exception {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Minimal handle over a spawned browser process — deliberately narrower
/// than `dart:io` [Process] so scripted-fake tests implement two members
/// instead of the full abstract class.
abstract interface class SessionProcess {
  /// OS process id (recorded as the `…-pid` sub-handle artifact).
  int get pid;

  /// Best-effort termination (`Process.kill` — SIGTERM semantics).
  bool kill();
}

/// Spawn seam: starts the browser binary with [chromeLaunchArgs]-built
/// argv. Injectable for scripted-fake lifecycle tests.
typedef SessionProcessStarter = Future<SessionProcess> Function(
  String executable,
  List<String> arguments,
);

final class _IoSessionProcess implements SessionProcess {
  _IoSessionProcess(this._process);

  final Process _process;

  @override
  int get pid => _process.pid;

  @override
  bool kill() => _process.kill();
}

/// Default [SessionProcessStarter]: `dart:io` `Process.start` (detached —
/// the browser outlives the step; the step only records the pid).
Future<SessionProcess> startSessionProcess(
  final String executable,
  final List<String> arguments,
) async {
  final process = await Process.start(executable, arguments, mode: ProcessStartMode.detached);
  return _IoSessionProcess(process);
}

// -- Target ------------------------------------------------------------------

/// The `chrome-session` target (ADR-0017 §3): ensure a Chrome browser
/// session is running, idempotently, and provide the session-handle
/// artifacts (ADR-0017 §2 convention).
class ChromeSessionTarget extends Target {
  /// Creates the target. [spec] is required (binaryPath has no safe
  /// default — provisioning is deferred, ADR-0017 S1).
  const ChromeSessionTarget({required this.spec, this.sessionName = 'main'});

  /// The session description (the "what" seam, ADR-0017 §1).
  final BrowserSessionSpec spec;

  /// Session instance name, namespacing the artifact ids:
  /// `session-chrome-<sessionName>-handle`. Distinct names allow
  /// concurrent distinct sessions without artifact-id collisions.
  ///
  /// Named `sessionName` rather than `name` because [Target.name] is
  /// already the CLI identifier (`chrome-session`).
  final String sessionName;

  @override
  String get name => 'chrome-session';

  @override
  String get description =>
      'Ensure a Chrome browser session is running (idempotent CDP reuse, '
      'readiness via /json/version probe, '
      '${spec.profilePersistence.label} profile) — provides '
      '${chromeSessionHandleArtifactId(sessionName)} '
      '(ADR-0017 session-handle convention)';

  @override
  List<BuildStep> compile(final BuildContext ctx) => [
        EnsureChromeSessionStep(spec: spec, sessionName: sessionName),
      ];

  @override
  String toString() =>
      'ChromeSessionTarget($sessionName, ${p.basename(spec.binaryPath)})';
}

// -- Steps -------------------------------------------------------------------

/// Ensures a Chrome session is answering CDP: reuse if the port already
/// answers (idempotent, EmulatorTarget semantics), else spawn + readiness
/// probe. Provides the ADR-0017 §2 session-handle artifacts.
///
/// Injectable seams ([CdpProbe], [SessionProcessStarter], ephemeral-port
/// assigner) default to real implementations; lifecycle tests substitute
/// scripted fakes exactly like EmulatorTarget's injected `runProcess`.
class EnsureChromeSessionStep extends BuildStep {
  /// Creates the step. [probe], [startProcess], and [assignPort] default
  /// to the real implementations; tests inject fakes.
  EnsureChromeSessionStep({
    required this.spec,
    this.sessionName = 'main',
    this.pollInterval = const Duration(milliseconds: 200),
    CdpProbe? probe,
    SessionProcessStarter? startProcess,
    Future<int> Function()? assignPort,
    bool Function(int pid)? killProcess,
  })  : _probe = probe ?? httpCdpProbe,
        _startProcess = startProcess ?? startSessionProcess,
        _assignPort = assignPort ?? assignEphemeralPort,
        _killProcess = killProcess ?? Process.killPid;

  /// The session spec (validated fail-closed at run start, ADR-0017 §3).
  final BrowserSessionSpec spec;

  /// Session instance name — namespaces the artifact ids.
  final String sessionName;

  /// Poll cadence for the readiness probe (tests shrink this).
  final Duration pollInterval;

  final CdpProbe _probe;
  final SessionProcessStarter _startProcess;
  final Future<int> Function() _assignPort;
  final bool Function(int pid) _killProcess;

  /// `session-chrome-<name>-handle` — the CDP base URL ([String]).
  late final Artifact<String> handleArtifact =
      Artifact<String>(chromeSessionHandleArtifactId(sessionName));

  /// `session-chrome-<name>-cdp-port` — the CDP port ([int]).
  late final Artifact<int> portArtifact =
      Artifact<int>(chromeSessionCdpPortArtifactId(sessionName));

  /// `session-chrome-<name>-pid` — spawned browser pid (spawn path only).
  late final Artifact<int> pidArtifact =
      Artifact<int>(chromeSessionPidArtifactId(sessionName));

  /// `session-chrome-<name>-profile-dir` — the ephemeral profile dir oka
  /// created (ephemeral spawn path only; never set for reused or
  /// persistent sessions so teardown can only ever delete oka-owned dirs).
  late final Artifact<String> profileDirArtifact =
      Artifact<String>(chromeSessionProfileDirArtifactId(sessionName));

  @override
  String get name => 'ensure-chrome-session';

  @override
  Set<Artifact<Object>> get provides => {handleArtifact, portArtifact};

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    // Fail-closed spec validation (ADR-0017 §3): a mis-typed spec fails
    // with the accepted surface named before any process is touched.
    final issues = chromeSessionIssues(spec);
    if (issues.isNotEmpty) {
      return StepResult.failure(
        'Chrome session "$sessionName" spec is invalid (fail-closed, '
        'ADR-0017 §3):\n'
        '${issues.map((final i) => '  - $i').join('\n')}',
      );
    }

    final port = spec.debugPort ?? await _assignPort();
    final baseUrl = 'http://127.0.0.1:$port';
    final probeUrl = Uri.parse('$baseUrl/json/version');

    // Idempotent reuse: a port that already answers CDP is reused, never
    // spawned against (EmulatorTarget reuse semantics, ADR-0017 §1).
    final existing = await _probe(probeUrl);
    final existingBrowser = existing == null ? null : parseVersionJson(existing);
    if (existingBrowser != null) {
      print(
        '✅ Chrome session "$sessionName" already answering CDP '
        '($existingBrowser) — reusing $baseUrl.',
      );
      state[handleArtifact.id] = baseUrl;
      state[portArtifact.id] = port;
      return StepResult.success({
        handleArtifact.id: baseUrl,
        'reused': 'true',
        'browser': existingBrowser,
      });
    }

    // Profile dir: ephemeral = fresh system-temp dir (test/agent posture,
    // deleted by StopChromeSessionStep); persistent = stable dir under the
    // build dir (dev posture, survives the command — ADR-0017 §5).
    final bool ephemeralDir;
    final String profileDir;
    if (spec.profilePersistence == ProfilePersistence.ephemeral) {
      ephemeralDir = true;
      profileDir = (await Directory.systemTemp
              .createTemp('oka-chrome-$sessionName-'))
          .path;
    } else {
      ephemeralDir = false;
      profileDir = p.join(ctx.buildDir, 'chrome-profiles', sessionName);
      await Directory(profileDir).create(recursive: true);
    }

    final args = chromeLaunchArgs(
      debugPort: port,
      profileDir: profileDir,
      flags: spec.launchFlags,
      headless: spec.headless,
      windowSize: spec.windowSize,
    );

    print(
      '🌐 Starting Chrome session "$sessionName" '
      '(${p.basename(spec.binaryPath)}, CDP port $port, '
      '${spec.profilePersistence.label} profile)…',
    );

    final SessionProcess process;
    try {
      process = await _startProcess(spec.binaryPath, args);
    } on Exception catch (e) {
      return StepResult.failure(
        'Failed to start "${spec.binaryPath}": $e\n'
        'Remedies: confirm binaryPath points at a Chromium binary (browser '
        'provisioning is deferred, ADR-0017 out-of-scope/S1); run '
        '"${spec.binaryPath} ${args.take(2).join(' ')}" manually to see '
        'startup errors.',
      );
    }
    // The browser process runs for the session's lifetime — never awaited
    // (same posture as the emulator boot step); only the pid is recorded.

    // Readiness probe: poll /json/version until it answers within the
    // boot timeout. Plain HTTP only — no CDP client (ADR-0017).
    final deadline = DateTime.now().add(spec.bootTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final body = await _probe(probeUrl);
      final browser = body == null ? null : parseVersionJson(body);
      if (browser != null) {
        state[handleArtifact.id] = baseUrl;
        state[portArtifact.id] = port;
        state[pidArtifact.id] = process.pid;
        if (ephemeralDir) state[profileDirArtifact.id] = profileDir;
        print(
          '✅ Chrome session "$sessionName" ready ($browser) — '
          'CDP at $baseUrl.',
        );
        return StepResult.success({
          handleArtifact.id: baseUrl,
          'browser': browser,
        });
      }
      await Future<void>.delayed(pollInterval);
    }

    // Timed out: never leave a half-booted browser behind.
    _killProcess(process.pid);
    return StepResult.failure(
      'Chrome session "$sessionName" did not answer CDP at '
      '$baseUrl/json/version within ${spec.bootTimeout.inSeconds}s.\n'
      'Remedies: (1) confirm binaryPath "${spec.binaryPath}" is a Chromium '
      'binary that starts (try it manually with the same '
      '--remote-debugging-port); (2) if another process holds port $port, '
      'stop it or set debugPort explicitly; (3) try headless: false to '
      'surface startup dialogs or crashes.',
    );
  }
}

/// Stops a Chrome session started by [EnsureChromeSessionStep] and deletes
/// its ephemeral profile dir (best effort) — compose into teardown targets,
/// the StopEmulatorStep precedent.
///
/// Scoped by what oka recorded: only the pid oka spawned is killed, and
/// only an ephemeral dir oka created is deleted — a reused (pre-existing)
/// session is left running and untouched, matching the reuse contract.
class StopChromeSessionStep extends BuildStep {
  /// Creates the step. [pid] overrides the recorded pid (explicit
  /// composition without the ensure step upstream); [killProcess]
  /// defaults to `Process.killPid` (tests inject a recording fake).
  StopChromeSessionStep({
    this.sessionName = 'main',
    this.pid,
    bool Function(int pid)? killProcess,
  }) : _killProcess = killProcess ?? Process.killPid;

  /// Session instance name — must match the ensure step's name.
  final String sessionName;

  /// Explicit pid override; null → the recorded `…-pid` artifact.
  final int? pid;

  final bool Function(int pid) _killProcess;

  @override
  String get name => 'stop-chrome-session';

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async {
    final pidValue = pid ?? state[chromeSessionPidArtifactId(sessionName)];
    final profileDir =
        state[chromeSessionProfileDirArtifactId(sessionName)] as String?;

    if (pidValue is! int && (profileDir == null || profileDir.isEmpty)) {
      return StepResult.failure(
        'No chrome session "$sessionName" recorded to stop — run the '
        'chrome-session target first (or declare StopChromeSessionStep '
        '(pid: ...) explicitly). A reused session records no pid and is '
        'deliberately not stopped.',
      );
    }

    if (pidValue is int) {
      final killed = _killProcess(pidValue);
      print(
        killed
            ? '🛑 Chrome session "$sessionName" stopped (pid $pidValue).'
            : '⚠️ Chrome session "$sessionName" pid $pidValue was not '
                'running (already stopped?).',
      );
    }
    if (profileDir != null && profileDir.isNotEmpty) {
      try {
        Directory(profileDir).deleteSync(recursive: true);
      } on FileSystemException catch (e) {
        // Best effort: the OS clears system temp eventually; a locked dir
        // must not fail an otherwise-successful teardown.
        print('⚠️ Could not delete ephemeral profile dir "$profileDir": '
            '${e.message}');
      }
    }
    return StepResult.success();
  }
}
