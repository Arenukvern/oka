/// The `chrome-session` target (ADR-0017 §3): Chrome-first browser session
/// as a composable target — the second instance of the EmulatorTarget
/// pattern (ADR-0017 Context), not a new mechanism.
///
/// What it does, per run:
///
/// 1. **Ensure session, idempotently** — if something already answers CDP
///    on the chosen port, it is *reused* (never spawned against; the same
///    semantics as EmulatorTarget reusing a running emulator). Otherwise
///    the binary is spawned with `--remote-debugging-port`, an isolated
///    managed profile (unless [BrowserSessionSpec.profilePersistence] is
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
///    kind. Sub-handles `…-pid` / `…-profile-dir` support teardown and state
///    reconciliation.
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
/// automatic end-of-run hook, so process teardown is a step, not magic.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;

import 'browser_session_spec.dart';
import 'chrome_profile_state.dart';

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

bool _validSessionName(final String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(value) &&
    value != '.' &&
    value != '..';

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
}) => [
  '--remote-debugging-port=$debugPort',
  '--user-data-dir=$profileDir',
  if (headless) '--headless',
  // Automation posture: suppress first-run / default-browser prompts —
  // headful sessions must boot unattended too (agents never click
  // through dialogs).
  '--no-first-run',
  '--no-default-browser-check',
  if (windowSize != null)
    '--window-size=${windowSize.width}x${windowSize.height}',
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
    final request = await client
        .getUrl(url)
        .timeout(const Duration(seconds: 2));
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
typedef SessionProcessStarter =
    Future<SessionProcess> Function(String executable, List<String> arguments);

final class _IoSessionProcess implements SessionProcess {
  /// Wraps a real [Process] as a [SessionProcess].
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
  final process = await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.detached,
  );
  return _IoSessionProcess(process);
}

// -- Target ------------------------------------------------------------------

/// The `chrome-session` target (ADR-0017 §3): ensure a Chrome browser
/// session is running, idempotently, and provide the session-handle
/// artifacts (ADR-0017 §2 convention).
class ChromeSessionTarget extends Target
    implements SessionStateWorkflowContributor {
  /// Creates the target. [spec] is required (binaryPath has no safe
  /// default — provisioning is deferred, ADR-0017 S1).
  const ChromeSessionTarget({
    required this.spec,
    this.sessionName = 'main',
    this.stateWorkflow = chromeProfileStateWorkflow,
  });

  /// The session description (the "what" seam, ADR-0017 §1).
  final BrowserSessionSpec spec;

  /// Session instance name, namespacing the artifact ids:
  /// `session-chrome-<sessionName>-handle`. Distinct names allow
  /// concurrent distinct sessions without artifact-id collisions.
  ///
  /// Named `sessionName` rather than `name` because [Target.name] is
  /// already the CLI identifier (`chrome-session`).
  final String sessionName;

  /// Composable state lifecycle; defaults to Oka's Chromium implementation.
  final SessionStateWorkflow<ChromeProfileHandle> stateWorkflow;

  @override
  List<SessionStateWorkflow<dynamic>> get sessionStateWorkflows => [
    stateWorkflow,
  ];

  /// Target name: `chrome-session`.
  @override
  String get name => 'chrome-session';

  /// Explain-text: idempotency posture, probe mechanism, profile
  /// persistence, and the provided session-handle artifact.
  @override
  String get description =>
      'Ensure a Chrome browser session is running (idempotent CDP reuse, '
      'readiness via /json/version probe, '
      '${spec.effectiveStateRetention.label} state / '
      '${spec.effectiveProcessScope.label} process) — provides '
      '${chromeSessionHandleArtifactId(sessionName)} '
      '(ADR-0017 session-handle convention)';

  /// Pure session-state posture and configuration validation for
  /// `oka explain --targets`; this performs no browser or filesystem I/O.
  @override
  List<String> explainDetails(final BuildContext ctx) {
    final inspectorIds = stateWorkflow.inspectors
        .map((final inspector) => inspector.id)
        .join(', ');
    final reuseInspectorIds = stateWorkflow.reuseInspectors
        ?.map((final inspector) => inspector.id)
        .join(', ');
    final issues = [...chromeSessionIssues(spec), ...stateWorkflow.validate()];
    return [
      'session-state workflow: ${stateWorkflow.id}@${stateWorkflow.version}',
      'session-state retention: ${spec.effectiveStateRetention.label}',
      'session-state inspectors: ${inspectorIds.isEmpty ? '(none)' : inspectorIds}',
      'session-state reuse inspectors: ${reuseInspectorIds == null || reuseInspectorIds.isEmpty ? '(same as inspectors)' : reuseInspectorIds}',
      if (issues.isEmpty)
        'session-state validation: valid'
      else ...[
        'session-state validation issues:',
        for (final issue in issues) '  - $issue',
      ],
    ];
  }

  /// Compile to the ensure step (single step; stop is a separate target).
  @override
  List<BuildStep> compile(final BuildContext ctx) => [
    EnsureChromeSessionStep(
      spec: spec,
      sessionName: sessionName,
      stateWorkflow: stateWorkflow,
    ),
  ];

  /// Process teardown follows the independent process scope. It never removes
  /// profile state retained beyond that process.
  @override
  List<BuildStep> compileTeardown(final BuildContext ctx) =>
      spec.effectiveProcessScope == LeaseScope.ephemeral
      ? [StopChromeSessionStep(sessionName: sessionName)]
      : const <BuildStep>[];

  /// Debug string: session name plus browser binary basename.
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
  /// to the real implementations; tests inject fakes. [liveness] and
  /// [leaseRegistry] are the ADR-0018 seams (injectable for tests); when
  /// null they default to [HostProcessLiveness] and the standard project
  /// registry location.
  EnsureChromeSessionStep({
    required this.spec,
    this.sessionName = 'main',
    this.pollInterval = const Duration(milliseconds: 200),
    this.killGrace = const Duration(milliseconds: 1500),
    this.ownerCmd = 'oka run chrome-session',
    CdpProbe? probe,
    SessionProcessStarter? startProcess,
    Future<int> Function()? assignPort,
    this.liveness,
    this.leaseRegistry,
    this.stateRegistry,
    this.stateWorkflow = chromeProfileStateWorkflow,
  }) : _probe = probe ?? httpCdpProbe,
       _startProcess = startProcess ?? startSessionProcess,
       _assignPort = assignPort ?? assignEphemeralPort;

  /// The session spec (validated fail-closed at run start, ADR-0017 §3).
  final BrowserSessionSpec spec;

  /// Session instance name — namespaces the artifact ids.
  final String sessionName;

  /// Poll cadence for the readiness probe (tests shrink this).
  final Duration pollInterval;

  final CdpProbe _probe;
  final SessionProcessStarter _startProcess;
  final Future<int> Function() _assignPort;

  /// How long the spawned browser gets to exit after the graceful SIGTERM
  /// before the timeout path escalates (ADR-0018 §1 graceful-first ladder;
  /// tests shrink this).
  final Duration killGrace;

  /// Recorded in the lease's `owner_cmd` (ADR-0018 §1).
  final String ownerCmd;

  /// Platform liveness/identity/kill seam (ADR-0018 §1); null →
  /// [HostProcessLiveness]. Injectable for scripted-fake tests.
  final ProcessLiveness? liveness;

  /// Lease registry override; null → the standard project location
  /// (`<project>/.oka_cache/processes/`). Injectable for tests.
  final ProcessLeaseRegistry? leaseRegistry;

  /// Durable user-global state registry override; null uses the Oka default.
  final SessionStateRegistry? stateRegistry;

  /// Typed workflow for profile planning, provisioning and inspection.
  final SessionStateWorkflow<ChromeProfileHandle> stateWorkflow;

  ProcessLiveness get _host => liveness ?? const HostProcessLiveness();

  /// Lease id for this session — the ADR §1 shape (`chrome-<name>`).
  @visibleForTesting
  String get leaseId => 'chrome-$sessionName';

  /// `session-chrome-<name>-handle` — the CDP base URL ([String]).
  late final Artifact<String> handleArtifact = Artifact<String>(
    chromeSessionHandleArtifactId(sessionName),
  );

  /// `session-chrome-<name>-cdp-port` — the CDP port ([int]).
  late final Artifact<int> portArtifact = Artifact<int>(
    chromeSessionCdpPortArtifactId(sessionName),
  );

  /// `session-chrome-<name>-pid` — spawned browser pid (spawn path only).
  late final Artifact<int> pidArtifact = Artifact<int>(
    chromeSessionPidArtifactId(sessionName),
  );

  /// `session-chrome-<name>-profile-dir` — the Oka-managed profile directory
  /// (ephemeral spawn path only; teardown leaves it for verified state
  /// reconciliation).
  late final Artifact<String> profileDirArtifact = Artifact<String>(
    chromeSessionProfileDirArtifactId(sessionName),
  );

  /// Step name: `ensure-chrome-session`.
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
    if (!_validSessionName(sessionName)) {
      return StepResult.failure(
        'Chrome session name "$sessionName" is invalid. Use 1–64 ASCII '
        'letters, digits, dots, underscores, or hyphens, starting with a '
        'letter or digit.',
      );
    }
    final workflowIssues = stateWorkflow.validate();
    if (workflowIssues.isNotEmpty) {
      return StepResult.failure(
        'Chrome session-state workflow is invalid:\n'
        '${workflowIssues.map((final issue) => '  - $issue').join('\n')}',
      );
    }

    final port = spec.debugPort ?? await _assignPort();
    final baseUrl = 'http://127.0.0.1:$port';
    final probeUrl = Uri.parse('$baseUrl/json/version');

    // Idempotent reuse: a port that already answers CDP is reused, never
    // spawned against (EmulatorTarget reuse semantics, ADR-0017 §1).
    final existing = await _probe(probeUrl);
    final existingBrowser = existing == null
        ? null
        : parseVersionJson(existing);
    if (existingBrowser != null) {
      print(
        '✅ Chrome session "$sessionName" already answering CDP '
        '($existingBrowser) — reusing $baseUrl.',
      );
      await _adoptLease(port, ctx);
      state[handleArtifact.id] = baseUrl;
      state[portArtifact.id] = port;
      return StepResult.success({
        handleArtifact.id: baseUrl,
        'reused': 'true',
        'browser': existingBrowser,
      });
    }

    final ephemeralState =
        spec.effectiveStateRetention == SessionStateRetention.ephemeral;
    var profileRootPath = ctx.projectPath;
    var relativeProfilePath = p.posix.join(
      '.oka_cache',
      'session-state',
      'chrome',
      sessionName,
    );
    var stateOwnership = SessionStateOwnership.oka;
    var acquisitionMode = SessionStateAcquisitionMode.created;
    if (!ephemeralState) {
      profileRootPath = ctx.buildDir;
      relativeProfilePath = p.posix.join('chrome-profiles', sessionName);
      try {
        // buildDir is an existing Oka surface and may be user-configured.
        // Create only the root here; the state manager reserves and creates
        // the profile directory itself after recording its durable lease.
        await Directory(profileRootPath).create(recursive: true);
      } on Object catch (error) {
        return StepResult.failure(
          'Could not prepare Chrome profile build directory '
          '"$profileRootPath": $error',
        );
      }

      final registry = stateRegistry ?? SessionStateRegistry.forCurrentUser();
      final snapshot = await registry.inspect();
      final logicalKey = 'chrome-profile:${ctx.projectPath}:$sessionName';
      final matchingLeases = snapshot.leases.where(
        (final lease) => lease.logicalResourceKey == logicalKey,
      );
      if (snapshot.issues.isEmpty && matchingLeases.length == 1) {
        final lease = matchingLeases.single;
        // The lease, not the current build-directory setting, is the source of
        // truth for an existing persistent profile. This preserves its path
        // across configuration changes; acquire() revalidates workflow,
        // ownership, host, marker, and resource safety before reuse.
        profileRootPath = lease.rootPath;
        relativeProfilePath = lease.relativePath;
        stateOwnership = lease.ownership;
        acquisitionMode = lease.acquisitionMode;
      } else if (matchingLeases.isEmpty) {
        final legacyProfilePath = p.join(profileRootPath, relativeProfilePath);
        if (await FileSystemEntity.type(
              legacyProfilePath,
              followLinks: false,
            ) ==
            FileSystemEntityType.directory) {
          // Prior releases created persistent profiles directly under
          // buildDir without a state lease. Borrow them in place: never move,
          // copy, or delete a user's existing cookies/login state.
          stateOwnership = SessionStateOwnership.caller;
          acquisitionMode = SessionStateAcquisitionMode.borrowed;
        }
      }
    }
    final SessionStateLease stateLease;
    try {
      stateLease =
          await SessionStateManager(
            registry: stateRegistry ?? SessionStateRegistry.forCurrentUser(),
            liveness: _host,
          ).acquire(
            stateWorkflow,
            SessionStateRequest(
              projectPath: ctx.projectPath,
              sessionName: sessionName,
              metadata: {
                'state_root': profileRootPath,
                'relative_path': relativeProfilePath,
                'state_retention': spec.effectiveStateRetention.label,
                'process_scope': spec.effectiveProcessScope.label,
                'state_ownership': stateOwnership.label,
                'acquisition_mode': acquisitionMode.label,
                'process_snapshot_required': false,
              },
            ),
          );
    } on Object catch (error) {
      return StepResult.failure(
        'Could not reserve Chromium profile state before launch: $error',
      );
    }
    final profileDir = p.join(stateLease.rootPath, stateLease.relativePath);
    if (ephemeralState) state[profileDirArtifact.id] = profileDir;
    final SessionStateWorkflowSession restored;
    final List<SessionStateFinding> profileFindings;
    try {
      restored = await stateWorkflow.restoreSession(stateLease, forReuse: true);
      profileFindings = await restored.inspect(stateLease);
    } on Object catch (error) {
      return StepResult.failure(
        'Could not inspect reserved Chrome profile "$profileDir" '
        '(lease ${stateLease.id}); no browser was launched: $error',
      );
    }
    final profileVeto = profileFindings.firstWhere(
      (final finding) => finding.use != SessionStateUse.unused,
      orElse: () => const SessionStateFinding(
        inspectorId: 'oka.profile-inspection',
        use: SessionStateUse.unused,
        reason: 'all composed profile inspectors affirm unused.',
      ),
    );
    if (profileVeto.use != SessionStateUse.unused) {
      return StepResult.failure(
        'Chrome profile "$profileDir" cannot be used safely: '
        '${profileVeto.inspectorId}: ${profileVeto.reason}',
      );
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
      '${spec.effectiveStateRetention.label} profile)…',
    );

    final stateManager = SessionStateManager(
      registry: stateRegistry ?? SessionStateRegistry.forCurrentUser(),
      liveness: _host,
    );
    final SessionProcess? process;
    var processSnapshotRequired = false;
    try {
      await stateManager.expectProcess(stateLease.id);
      processSnapshotRequired = true;
      process = await _startProcess(spec.binaryPath, args);
    } on Object catch (e) {
      if (processSnapshotRequired) {
        try {
          await stateManager.markProcessNotStarted(stateLease.id);
        } on Object catch (error) {
          print(
            '⚠️ Could not clear the pre-spawn process marker for session '
            'state ${stateLease.id}: $error',
          );
        }
      }
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
    // The handle itself is kept (ADR-0018 problem A): the readiness
    // timeout below stops exactly the process we spawned.

    // Record both process and state identity immediately after spawn. The
    // durable state association is authoritative; the process lease remains
    // the existing advisory stop surface.
    final String? pidToken = await _identityToken(process.pid);
    if (pidToken == null) {
      final stopped = await _stopSpawned(
        process,
        null,
        ctx,
        stateManager: stateManager,
        stateLeaseId: stateLease.id,
      );
      return StepResult.failure(
        'Chrome spawned as pid ${process.pid}, but its process identity token '
        'could not be verified. The process was '
        '${stopped ? 'stopped' : 'not verified stopped'}; the durable '
        'pre-spawn expectation ${stopped ? 'was cleared' : 'was retained'} '
        'for recovery.',
      );
    }
    await _upsertLease(
      spawnLease(process.pid, pidToken, port: port, profileDir: profileDir),
      ctx,
    );
    try {
      await stateManager.attachProcess(
        leaseId: stateLease.id,
        processLeaseId: leaseId,
        processPid: process.pid,
        processPidToken: pidToken,
      );
    } on Object catch (error) {
      final stopped = await _stopSpawned(
        process,
        pidToken,
        ctx,
        stateManager: stateManager,
        stateLeaseId: stateLease.id,
      );
      return StepResult.failure(
        'Chrome spawned as pid ${process.pid}, but the durable state lease '
        'could not record it: $error. The process was '
        '${stopped ? 'stopped' : 'not verified stopped'}; session state was '
        'retained for inspection.',
      );
    }

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

    // Timed out: never leave a half-booted browser behind (ADR-0018
    // problem A — identity-verified stop of exactly the spawned process).
    final stopped = await _stopSpawned(
      process,
      pidToken,
      ctx,
      stateManager: stateManager,
      stateLeaseId: stateLease.id,
    );
    return StepResult.failure(
      'Chrome session "$sessionName" did not answer CDP at '
      '$baseUrl/json/version within ${spec.bootTimeout.inSeconds}s.\n'
      'Remedies: (1) confirm binaryPath "${spec.binaryPath}" is a Chromium '
      'binary that starts (try it manually with the same '
      '--remote-debugging-port); (2) if another process holds port $port, '
      'stop it or set debugPort explicitly; (3) try headless: false to '
      'surface startup dialogs or crashes.'
      '${stopped ? ' The spawned browser process was stopped.' : ''}',
    );
  }

  // -- Lease recording + identity-verified failure-path kill (ADR-0018) ---

  ProcessLeaseRegistry _registryFor(final BuildContext ctx) =>
      leaseRegistry ??
      ProcessLeaseRegistry.forProject(ctx.projectPath, liveness: _host);

  /// The spawned-browser lease (kind `chrome-session`, ownership owned,
  /// scope from the spec's profile persistence — an ephemeral temp profile
  /// is an ephemeral session, a persistent profile is a persistent
  /// session). Identity: cdp port + the pid start-time token when
  /// obtainable. Stop hint: the graceful SIGTERM of the recorded pid.
  @visibleForTesting
  ProcessLease spawnLease(
    final int pid,
    final String? pidToken, {
    required final int port,
    final String? profileDir,
  }) => ProcessLease(
    id: leaseId,
    pid: pid,
    kind: 'chrome-session',
    identity: {
      'cdp_port': '$port',
      'profile_dir': ?profileDir,
      'session_name': sessionName,
      processLeasePidTokenKey: ?pidToken,
    },
    scope: spec.effectiveProcessScope,
    ownership: LeaseOwnership.owned,
    ownerCmd: ownerCmd,
    startedAt: DateTime.now().toUtc(),
    stopHint: LeaseStopHint(tool: 'kill', args: ['$pid']),
  );

  /// Adopt path (ADR-0018 §3): flip any existing lease for this session to
  /// ownership `borrowed`; if none exists, record one as borrowed (pid 0 —
  /// adopted by semantic discovery, the CDP port). Never kills anything.
  Future<void> _adoptLease(final int port, final BuildContext ctx) async {
    try {
      final registry = _registryFor(ctx);
      for (final lease in await registry.list()) {
        if (lease.kind == 'chrome-session' &&
            lease.identity['cdp_port'] == '$port') {
          if (lease.ownership == LeaseOwnership.borrowed) return;
          await registry.upsert(
            lease.copyWith(
              identity: {...lease.identity, 'cdp_port': '$port'},
              ownership: LeaseOwnership.borrowed,
            ),
          );
          return;
        }
      }
      await registry.upsert(
        ProcessLease(
          id: leaseId,
          pid: 0,
          kind: 'chrome-session',
          identity: {'cdp_port': '$port'},
          scope: spec.effectiveProcessScope,
          ownership: LeaseOwnership.borrowed,
          ownerCmd: ownerCmd,
          startedAt: DateTime.now().toUtc(),
          stopHint: const LeaseStopHint(tool: 'kill'),
        ),
      );
    } on Object catch (e) {
      // Leases are advisory: a failed record must never fail a build.
      print('⚠️ Could not record borrowed chrome-session lease: $e');
    }
  }

  /// Identity-verified, graceful-first stop of the spawned browser
  /// process (ADR-0018 §1 identity-over-pid) plus lease cleanup. Never
  /// signals an unverifiable pid (report-never-guess; the reconcile sweep
  /// in L2 surfaces what we could not stop).
  Future<bool> _stopSpawned(
    final SessionProcess? process,
    final String? pidToken,
    final BuildContext ctx, {
    required final SessionStateManager stateManager,
    required final String stateLeaseId,
  }) async {
    if (process == null) return true; // nothing spawned, nothing to clean
    if (pidToken == null) {
      // The pid-token gate intentionally forbids signaling by pid. The
      // process handle is still authoritative for the process just spawned;
      // clear the durable pre-spawn expectation only after liveness confirms
      // the process stopped. Otherwise leave recoverable state in place.
      try {
        process.kill();
      } on Object catch (error) {
        print('⚠️ Could not signal Chrome through its process handle: $error');
      }
      final deadline = DateTime.now().add(killGrace);
      while (true) {
        try {
          if (!await _host.isAlive(process.pid)) {
            await stateManager.markProcessNotStarted(stateLeaseId);
            await _registryFor(ctx).delete(leaseId);
            print(
              '🛑 Spawned chrome-session process (pid ${process.pid}) stopped '
              'through its process handle.',
            );
            return true;
          }
        } on Object catch (error) {
          print('⚠️ Could not verify handle-stopped Chrome process: $error');
          return false;
        }
        if (!DateTime.now().isBefore(deadline)) break;
        await Future<void>.delayed(pollInterval);
      }
      print(
        '⚠️ Chrome process ${process.pid} was signaled through its process '
        'handle, but stop could not be verified; session state was retained.',
      );
      return false;
    }
    final registry = _registryFor(ctx);
    final lease = await registry.read(leaseId);
    if (lease == null) return false;
    final outcome = await ProcessStopPolicy(
      registry: registry,
      liveness: _host,
      verifyGrace: killGrace,
      pollInterval: pollInterval,
    ).stop(lease, force: false, gracefulStop: (_) async => process.kill());
    if (outcome.disposition == ProcessStopDisposition.stopped) {
      print('🛑 Spawned chrome-session process (pid ${process.pid}) stopped.');
      return true;
    }
    print('⚠️ ${outcome.message ?? 'Chrome stop was not verified.'}');
    return false;
  }

  Future<void> _upsertLease(
    final ProcessLease lease,
    final BuildContext ctx,
  ) async {
    try {
      await _registryFor(ctx).upsert(lease);
    } on Object catch (e) {
      // Leases are advisory: a failed record must never fail a build.
      print('⚠️ Could not write chrome-session lease: $e');
    }
  }

  Future<String?> _identityToken(final int pid) async {
    try {
      return await _host.identityToken(pid);
    } on Object {
      return null;
    }
  }
}

/// Stops a Chrome session started by [EnsureChromeSessionStep]. Ephemeral
/// profile deletion is left to the durable session-state reconciler, which
/// rechecks ownership and profile use after this Oka process exits.
///
/// Scoped by what oka recorded: only the pid oka spawned is killed. A reused
/// (pre-existing) session is left running and untouched. Profile cleanup is
/// handled separately by the state reconciler after verifying inactivity.
class StopChromeSessionStep extends BuildStep {
  /// Creates the step. [pid] overrides the recorded pid (explicit
  /// composition without the ensure step upstream); [killProcess]
  /// defaults to `Process.killPid` (tests inject a recording fake).
  StopChromeSessionStep({
    this.sessionName = 'main',
    this.pid,
    this.liveness,
    this.leaseRegistry,
    bool Function(int pid)? killProcess,
  }) : _killProcess = killProcess ?? Process.killPid;

  /// Session instance name — must match the ensure step's name.
  final String sessionName;

  /// Explicit pid override; null → the recorded `…-pid` artifact.
  final int? pid;
  final ProcessLiveness? liveness;
  final ProcessLeaseRegistry? leaseRegistry;

  final bool Function(int pid) _killProcess;

  /// Step name: `stop-chrome-session`.
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

    var stopped = true;
    if (pidValue is int) {
      final registry =
          leaseRegistry ??
          ProcessLeaseRegistry.forProject(ctx.projectPath, liveness: liveness);
      final lease = await registry.read('chrome-$sessionName');
      if (lease != null) {
        if (lease.pid != pidValue) {
          return StepResult.failure(
            'Chrome handle pid $pidValue does not match lease pid ${lease.pid}; '
            'session and profile retained.',
          );
        }
        final outcome =
            await ProcessStopPolicy(
              registry: registry,
              liveness: liveness ?? const HostProcessLiveness(),
            ).stop(
              lease,
              force: false,
              gracefulStop: (_) async => _killProcess(pidValue),
            );
        stopped = outcome.ok;
        if (!stopped) {
          return StepResult.failure(outcome.message ?? 'Chrome stop failed.');
        }
      } else {
        if (pid == null) {
          return StepResult.failure(
            'No lease verifies Chrome pid $pidValue; session and profile retained.',
          );
        }
        // An explicit PID names the current external process. Capture its
        // identity now and use the same verified stop ladder. It grants no
        // authority over an ephemeral profile from an unrelated state handle.
        final host = liveness ?? const HostProcessLiveness();
        String? token;
        try {
          token = await host.identityToken(pidValue);
        } on Object {
          // Unknown identity is refused by the shared stop policy.
        }
        final external = ProcessLease(
          id: 'chrome-$sessionName',
          pid: pidValue,
          kind: 'chrome-session',
          identity: {processLeasePidTokenKey: ?token},
          scope: LeaseScope.ephemeral,
          ownership: LeaseOwnership.borrowed,
          ownerCmd: 'explicit Chrome stop',
          startedAt: DateTime.now().toUtc(),
          stopHint: LeaseStopHint(tool: 'kill', args: ['$pidValue']),
        );
        final outcome =
            await ProcessStopPolicy(registry: registry, liveness: host).stop(
              external,
              force: true,
              gracefulStop: (_) async => _killProcess(pidValue),
            );
        return outcome.ok
            ? StepResult.success()
            : StepResult.failure(outcome.message ?? 'Chrome stop failed.');
      }
      print(
        stopped
            ? '🛑 Chrome session "$sessionName" stopped (pid $pidValue).'
            : '⚠️ Chrome session "$sessionName" pid $pidValue was not '
                  'running (already stopped?).',
      );
    }
    if (stopped && profileDir != null && profileDir.isNotEmpty) {
      print(
        'ℹ️ Ephemeral Chrome profile "$profileDir" remains leased until '
        'session-state reconciliation verifies it is unused.',
      );
    }
    return StepResult.success();
  }
}
