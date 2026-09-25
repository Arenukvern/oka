// ADR-0017 S0 — ChromeSessionTarget: pure launch-arg / version-parse
// functions, compile() step shape, fail-closed spec issues, and the
// scripted-fake lifecycle (idempotent reuse, readiness polling, timeout
// remedy) — no real browser, no sockets, no CDP client.
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_web/oka_web.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Scripted-fake process: records argv + kill (EmulatorTarget test style).
class FakeSessionProcess implements SessionProcess {
  FakeSessionProcess(this.pid, {this.onKill});

  @override
  final int pid;

  bool killed = false;
  final void Function()? onKill;

  @override
  bool kill() {
    killed = true;
    onKill?.call();
    return true;
  }
}

/// Scripted-fake liveness seam (ADR-0018 §1): records kills, answers
/// identity from a fixed token — deterministic identity-gate tests.
class FakeLiveness implements ProcessLiveness {
  FakeLiveness({
    this.alive = true,
    this.token = 'tok-1',
    this.unidentifiablePids = const {},
    this.realIdentityPid,
  });

  bool alive;
  String? token;
  final Set<int> unidentifiablePids;
  final int? realIdentityPid;

  final List<int> killed = [];

  @override
  Future<bool> isAlive(final int pid) async => alive;

  @override
  Future<String?> identityToken(final int pid) async {
    if (unidentifiablePids.contains(pid)) return null;
    if (pid == realIdentityPid) {
      return const HostProcessLiveness().identityToken(pid);
    }
    return token;
  }

  @override
  Future<bool> kill(
    final int pid, {
    final Duration grace = const Duration(seconds: 3),
  }) async {
    killed.add(pid);
    alive = false;
    return true;
  }
}

BuildContext ctx(final Directory temp, {final String? buildDir}) =>
    BuildContext(
      projectPath: temp.path,
      buildDir: buildDir ?? p.join(temp.path, '.oka_cache', 'build', 'debug'),
      mode: BuildMode.debug,
      config: OkaConfig.empty,
    );

void main() {
  late Directory temp;
  late SessionStateRegistry stateRegistry;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('oka_chrome_target_');
    Directory(ctx(temp).buildDir).createSync(recursive: true);
    stateRegistry = SessionStateRegistry(
      Directory(
        p.join(temp.resolveSymbolicLinksSync(), '.session-state-registry'),
      ),
      bootId: 'test-boot',
    );
  });

  tearDown(() => temp.deleteSync(recursive: true));

  group('chromeLaunchArgs', () {
    test('golden: headless ephemeral session with explicit port', () {
      final args = chromeLaunchArgs(
        debugPort: 9222,
        profileDir: '/tmp/oka-chrome-1',
        flags: const [],
        headless: true,
      );
      expect(args, [
        '--remote-debugging-port=9222',
        '--user-data-dir=/tmp/oka-chrome-1',
        '--headless',
        '--no-first-run',
        '--no-default-browser-check',
      ]);
    });

    test('golden: headful session with window size', () {
      final args = chromeLaunchArgs(
        debugPort: 0,
        profileDir: '/tmp/profile',
        flags: const [],
        headless: false,
        windowSize: (width: 1280, height: 800),
      );
      expect(args, contains('--window-size=1280x800'));
      expect(args, isNot(contains('--headless')));
      // Automation flags apply headful too — agents never click dialogs.
      expect(args, contains('--no-first-run'));
      expect(args, contains('--no-default-browser-check'));
    });

    test('user flags are appended last (Chromium last-wins: add, never '
        'silently override)', () {
      final args = chromeLaunchArgs(
        debugPort: 9223,
        profileDir: '/tmp/p',
        flags: const ['--enable-features=WebModelContext', '--lang=de'],
        headless: true,
      );
      expect(args.first, '--remote-debugging-port=9223');
      expect(args.last, '--lang=de');
      expect(
        args.indexOf('--enable-features=WebModelContext'),
        greaterThan(args.indexOf('--headless')),
      );
    });
  });

  group('parseVersionJson', () {
    test('extracts the Browser field from a /json/version body', () {
      const body =
          '{"Browser":"Chrome/126.0.6478.126",'
          '"Protocol-Version":"1.3","webSocketDebuggerUrl":"ws://x"}';
      expect(parseVersionJson(body), 'Chrome/126.0.6478.126');
    });

    test('returns null for missing / empty Browser field', () {
      expect(parseVersionJson('{"Protocol-Version":"1.3"}'), isNull);
      expect(parseVersionJson('{"Browser":""}'), isNull);
    });

    test('returns null for invalid or non-object JSON', () {
      expect(parseVersionJson('not json'), isNull);
      expect(parseVersionJson('[]'), isNull);
      expect(parseVersionJson('"Chrome"'), isNull);
    });
  });

  group('chromeSessionIssues', () {
    BrowserSessionSpec specWithProtocol(final DebugProtocol protocol) =>
        BrowserSessionSpec(
          binaryPath: '/usr/bin/google-chrome',
          debugProtocol: protocol,
        );

    test('cdp is the accepted surface for Chrome (ADR-0017 §3)', () {
      expect(chromeSessionIssues(specWithProtocol(DebugProtocol.cdp)), isEmpty);
    });

    test('debugProtocol mismatch fails closed naming the accepted surface', () {
      for (final protocol in DebugProtocol.values) {
        if (protocol == DebugProtocol.cdp) continue;
        final issues = chromeSessionIssues(specWithProtocol(protocol));
        expect(issues, hasLength(1), reason: protocol.label);
        expect(issues.single, contains('DebugProtocol.cdp'));
        expect(issues.single, contains('Chrome speaks CDP only'));
      }
    });

    test('spec-level issues flow through', () {
      final issues = chromeSessionIssues(
        const BrowserSessionSpec(binaryPath: ''),
      );
      expect(issues, hasLength(1));
      expect(issues.single, contains('binaryPath is empty'));
    });
  });

  group('ChromeSessionTarget', () {
    const spec = BrowserSessionSpec(binaryPath: '/usr/bin/google-chrome');

    test('name passes ADR-0015 target-name validation', () {
      expect(
        validateTargetName(const ChromeSessionTarget(spec: spec).name),
        isNull,
      );
      expect(const ChromeSessionTarget(spec: spec).name, 'chrome-session');
    });

    test('contributes its configured custom session-state workflow', () {
      const customWorkflow = SessionStateWorkflow<ChromeProfileHandle>(
        id: 'test.custom-chrome',
        version: 1,
        plan: ChromeProfilePlanner(),
        source: ChromeProfileSource(),
      );
      const target = ChromeSessionTarget(
        spec: spec,
        stateWorkflow: customWorkflow,
      );

      final workflows = const Oka(
        pipelines: [],
        targets: [target],
      ).effectiveSessionStateWorkflows;
      expect(workflows, hasLength(1));
      expect(workflows.single, same(customWorkflow));
    });

    test('explain details include workflow posture and validation issues', () {
      const target = ChromeSessionTarget(
        spec: BrowserSessionSpec(
          binaryPath: '/usr/bin/google-chrome',
          profilePersistence: ProfilePersistence.persistent,
        ),
      );
      final details = describeTarget(target, ctx(temp)).details;
      expect(details, contains('session-state workflow: oka.chrome-profile@1'));
      expect(details, contains('session-state retention: persistent'));
      expect(
        details,
        contains('session-state inspectors: chrome-profile-singleton'),
      );
      expect(
        details,
        contains(
          'session-state reuse inspectors: chrome-profile-launch-singleton',
        ),
      );
      expect(details, contains('session-state validation: valid'));

      const invalidTarget = ChromeSessionTarget(
        spec: BrowserSessionSpec(
          binaryPath: '',
          debugProtocol: DebugProtocol.none,
        ),
        stateWorkflow: SessionStateWorkflow<ChromeProfileHandle>(
          id: 'test.workflow',
          version: 0,
          plan: ChromeProfilePlanner(),
          source: ChromeProfileSource(),
          inspectors: [ChromeProfileUseInspector()],
        ),
      );
      final invalidDetails = describeTarget(invalidTarget, ctx(temp)).details;
      expect(
        invalidDetails,
        contains('session-state workflow: test.workflow@0'),
      );
      expect(invalidDetails.join('\n'), contains('binaryPath is empty'));
      expect(invalidDetails.join('\n'), contains('Chrome speaks CDP only'));
      expect(invalidDetails.join('\n'), contains('version must be positive'));
    });

    test('compile produces ensure-chrome-session; chain validates; '
        'artifacts follow the ADR-0017 §2 convention', () {
      const target = ChromeSessionTarget(spec: spec);
      final steps = target.compile(ctx(temp));
      expect(steps.map((final s) => s.name).toList(), [
        'ensure-chrome-session',
      ]);
      expect(Pipeline(steps).validate(), isNull);

      final step = steps.single as EnsureChromeSessionStep;
      expect(step.handleArtifact.id, 'session-chrome-main-handle');
      expect(step.portArtifact.id, 'session-chrome-main-cdp-port');
      expect(step.provides.map((final a) => a.id).toSet(), {
        step.handleArtifact.id,
        step.portArtifact.id,
      });
      expect(target.description, contains('session-chrome-main-handle'));
    });

    test('sessionName namespaces the artifact ids', () {
      final step = EnsureChromeSessionStep(spec: spec, sessionName: 'showcase');
      expect(step.handleArtifact.id, 'session-chrome-showcase-handle');
      expect(step.portArtifact.id, 'session-chrome-showcase-cdp-port');
      expect(step.pidArtifact.id, 'session-chrome-showcase-pid');
      expect(step.profileDirArtifact.id, 'session-chrome-showcase-profile-dir');
    });

    test('config surface stays pure (no invocation args accepted)', () {
      const target = ChromeSessionTarget(spec: spec);
      expect(target.configOverrides, isEmpty);
      expect(
        () => target.applyInvocationArgs({'port': '9222'}),
        throwsArgumentError,
      );
    });
  });

  group('EnsureChromeSessionStep lifecycle (scripted fakes)', () {
    const binaryPath = '/usr/bin/google-chrome';
    const readyBody =
        '{"Browser":"Chrome/126.0.6478.126","Protocol-Version":"1.3"}';

    test(
      'Windows Chrome managed profile acquisition and launch setup',
      () async {
        if (!Platform.isWindows) return;
        var probes = 0;
        List<String>? launchArgs;
        final step = EnsureChromeSessionStep(
          stateRegistry: stateRegistry,
          liveness: FakeLiveness(alive: false),
          spec: const BrowserSessionSpec(
            binaryPath: binaryPath,
            debugPort: 9337,
            profilePersistence: ProfilePersistence.persistent,
          ),
          pollInterval: const Duration(milliseconds: 1),
          probe: (final url) async => ++probes == 1 ? null : readyBody,
          startProcess: (final executable, final args) async {
            launchArgs = args;
            return FakeSessionProcess(37);
          },
        );

        final result = await step.run(ctx(temp), PipelineState());

        expect(result.ok, isTrue, reason: result.error);
        expect(launchArgs, isNotNull);
        expect(launchArgs![1], startsWith('--user-data-dir='));
        final profilePath = launchArgs![1].substring('--user-data-dir='.length);
        expect(
          await File(sessionStateOwnershipMarkerPath(profilePath)).exists(),
          isTrue,
        );
        // The managed directory uses inherited Windows ACLs; dart:io cannot
        // verify those ACLs.
      },
    );

    test('reuse path: a port already answering CDP is reused, never '
        'spawned against (idempotent, ADR-0017 §1)', () async {
      var probes = 0;
      Uri? probedUrl;
      var spawns = 0;
      final step = EnsureChromeSessionStep(
        stateRegistry: stateRegistry,
        spec: const BrowserSessionSpec(binaryPath: binaryPath, debugPort: 9222),
        probe: (final url) async {
          probes++;
          probedUrl = url;
          return readyBody;
        },
        startProcess: (final exe, final args) async {
          spawns++;
          return FakeSessionProcess(1);
        },
      );
      final state = PipelineState();
      final result = await step.run(ctx(temp), state);

      expect(result.ok, isTrue, reason: result.error);
      expect(probes, 1);
      expect(spawns, 0, reason: 'reuse must not spawn');
      expect(probedUrl.toString(), 'http://127.0.0.1:9222/json/version');
      expect(state[step.handleArtifact.id], 'http://127.0.0.1:9222');
      expect(state[step.portArtifact.id], 9222);
      // A reused session records no pid — it is not ours to stop.
      expect(state[step.pidArtifact.id], isNull);
      expect(state[step.profileDirArtifact.id], isNull);
      expect(result.data['reused'], 'true');
      expect(
        (await stateRegistry.inspect()).leases,
        isEmpty,
        reason: 'port-only reuse has no known profile to lease',
      );
    });

    test('spawn path: probe answers after N attempts → artifacts + '
        'ephemeral profile dir recorded', () async {
      var probes = 0;
      final spawned = <List<String>>[];
      final processes = <FakeSessionProcess>[];
      final step = EnsureChromeSessionStep(
        stateRegistry: stateRegistry,
        liveness: FakeLiveness(),
        spec: const BrowserSessionSpec(
          binaryPath: binaryPath,
          launchFlags: ['--enable-features=WebModelContext'],
          bootTimeout: Duration(seconds: 5),
        ),
        pollInterval: const Duration(milliseconds: 1),
        probe: (final url) async {
          probes++;
          return probes < 3 ? null : readyBody;
        },
        startProcess: (final exe, final args) async {
          spawned.add(args);
          final process = FakeSessionProcess(4242);
          processes.add(process);
          return process;
        },
      );
      final state = PipelineState();
      final result = await step.run(ctx(temp), state);

      expect(result.ok, isTrue, reason: result.error);
      expect(spawned, hasLength(1));
      expect(probes, 3);
      final args = spawned.single;
      expect(args.first, startsWith('--remote-debugging-port='));
      final port = int.parse(args.first.split('=').last);
      final profileDir = args[1].split('=').last;
      expect(args[1], startsWith('--user-data-dir='));
      expect(Directory(profileDir).existsSync(), isTrue);
      expect(args, contains('--headless'));
      expect(args, contains('--enable-features=WebModelContext'));

      final baseUrl = 'http://127.0.0.1:$port';
      expect(state[step.handleArtifact.id], baseUrl);
      expect(state[step.portArtifact.id], port);
      expect(state[step.pidArtifact.id], 4242);
      expect(state[step.profileDirArtifact.id], profileDir);
      expect(result.data[step.handleArtifact.id], baseUrl);

      // Cleanup: the ephemeral profile dir the step created.
      Directory(profileDir).deleteSync(recursive: true);
    });

    test(
      'persistent profile honors the configured build dir (ADR-0017 §5)',
      () async {
        var probes = 0;
        String? profileDir;
        var spawns = 0;
        final step = EnsureChromeSessionStep(
          stateRegistry: stateRegistry,
          liveness: FakeLiveness(alive: false),
          spec: const BrowserSessionSpec(
            binaryPath: binaryPath,
            debugPort: 9333,
            profilePersistence: ProfilePersistence.persistent,
          ),
          pollInterval: const Duration(milliseconds: 1),
          probe: (final url) async {
            probes++;
            // The first probe is the reuse check — it must miss so the
            // spawn path is exercised.
            return probes == 1 ? null : readyBody;
          },
          startProcess: (final exe, final args) async {
            spawns++;
            profileDir = args[1].split('=').last;
            return FakeSessionProcess(7);
          },
        );
        final state = PipelineState();
        final buildDir = p.join(temp.path, 'custom-build-output');
        Directory(buildDir).createSync(recursive: true);
        final result = await step.run(ctx(temp, buildDir: buildDir), state);

        expect(result.ok, isTrue, reason: result.error);
        expect(spawns, 1, reason: 'reuse probe missed → exactly one spawn');
        expect(probes, 2);
        expect(
          profileDir,
          p.join(
            Directory(buildDir).resolveSymbolicLinksSync(),
            'chrome-profiles',
            'main',
          ),
        );
        // Persistent dirs are never recorded for teardown.
        expect(state[step.profileDirArtifact.id], isNull);

        var repeatProbes = 0;
        final repeatedStep = EnsureChromeSessionStep(
          stateRegistry: stateRegistry,
          liveness: FakeLiveness(alive: false),
          spec: const BrowserSessionSpec(
            binaryPath: binaryPath,
            debugPort: 9335,
            profilePersistence: ProfilePersistence.persistent,
          ),
          pollInterval: const Duration(milliseconds: 1),
          probe: (final url) async => ++repeatProbes == 1 ? null : readyBody,
          startProcess: (final exe, final args) async {
            expect(args[1], '--user-data-dir=$profileDir');
            return FakeSessionProcess(9);
          },
        );
        final repeatedResult = await repeatedStep.run(
          ctx(temp, buildDir: buildDir),
          PipelineState(),
        );
        expect(repeatedResult.ok, isTrue, reason: repeatedResult.error);
      },
    );

    test(
      'persistent relaunch accepts a dead lock without granting cleanup authority',
      () async {
        if (!Platform.isLinux && !Platform.isMacOS) return;
        final liveness = FakeLiveness(alive: false);
        final profileRoot = ctx(temp).buildDir;
        final manager = SessionStateManager(
          registry: stateRegistry,
          liveness: liveness,
        );
        final existingLease = await manager.acquire(
          chromeProfileStateWorkflow,
          SessionStateRequest(
            projectPath: temp.path,
            sessionName: 'main',
            metadata: {
              'state_root': profileRoot,
              'relative_path': p.posix.join('chrome-profiles', 'main'),
              'state_retention': SessionStateRetention.persistent.label,
              'process_scope': LeaseScope.persistent.label,
            },
          ),
        );
        await manager.expectProcess(existingLease.id);
        await manager.attachProcess(
          leaseId: existingLease.id,
          processLeaseId: 'chrome-main',
          processPid: 4242,
          processPidToken: 'token-4242',
        );
        final profileDir = p.join(
          existingLease.rootPath,
          existingLease.relativePath,
        );
        final cookies = File(p.join(profileDir, 'Cookies'));
        await cookies.writeAsString('saved profile data');
        await Link(
          p.join(profileDir, 'SingletonLock'),
        ).create('${Platform.localHostname}-4242');
        var probes = 0;
        final step = EnsureChromeSessionStep(
          stateRegistry: stateRegistry,
          liveness: liveness,
          spec: const BrowserSessionSpec(
            binaryPath: binaryPath,
            debugPort: 9337,
            profilePersistence: ProfilePersistence.persistent,
          ),
          pollInterval: const Duration(milliseconds: 1),
          probe: (final url) async => ++probes == 1 ? null : readyBody,
          startProcess: (final exe, final args) async {
            expect(args[1], '--user-data-dir=$profileDir');
            return FakeSessionProcess(11);
          },
        );

        final result = await step.run(ctx(temp), PipelineState());

        expect(result.ok, isTrue, reason: result.error);
        expect(
          cookies.readAsStringSync(),
          'saved profile data',
          reason: 'launch reuse must not rewrite profile contents',
        );
        expect((await stateRegistry.inspect()).leases, hasLength(1));
      },
    );

    test(
      'existing persistent profile is borrowed in place, not replaced',
      () async {
        final buildDir = ctx(temp).buildDir;
        final canonicalBuildDir = Directory(
          buildDir,
        ).resolveSymbolicLinksSync();
        final profileDir = p.join(canonicalBuildDir, 'chrome-profiles', 'main');
        Directory(profileDir).createSync(recursive: true);
        File(p.join(profileDir, 'Cookies')).writeAsStringSync('existing state');
        var probes = 0;
        final step = EnsureChromeSessionStep(
          stateRegistry: stateRegistry,
          liveness: FakeLiveness(),
          spec: const BrowserSessionSpec(
            binaryPath: binaryPath,
            debugPort: 9334,
            profilePersistence: ProfilePersistence.persistent,
          ),
          pollInterval: const Duration(milliseconds: 1),
          probe: (final url) async => ++probes == 1 ? null : readyBody,
          startProcess: (final exe, final args) async {
            expect(args[1], '--user-data-dir=$profileDir');
            return FakeSessionProcess(8);
          },
        );

        final result = await step.run(ctx(temp), PipelineState());

        expect(result.ok, isTrue, reason: result.error);
        expect(
          File(p.join(profileDir, 'Cookies')).readAsStringSync(),
          'existing state',
        );
        final states = await stateRegistry.inspect();
        expect(states.leases, hasLength(1));
        expect(states.leases.single.ownership, SessionStateOwnership.caller);
        expect(
          states.leases.single.acquisitionMode,
          SessionStateAcquisitionMode.borrowed,
        );
      },
    );

    test(
      'existing persistent lease keeps its path after buildDir changes',
      () async {
        final previousBuildDir = p.join(temp.path, 'previous-build');
        await Directory(previousBuildDir).create(recursive: true);
        const previousRelativePath = 'chrome-profiles/main';
        final previousLease = await SessionStateManager(registry: stateRegistry)
            .acquire(
              chromeProfileStateWorkflow,
              SessionStateRequest(
                projectPath: temp.path,
                sessionName: 'main',
                metadata: {
                  'state_root': previousBuildDir,
                  'relative_path': previousRelativePath,
                  'state_retention': SessionStateRetention.persistent.label,
                  'process_scope': LeaseScope.persistent.label,
                },
              ),
            );
        final profileDir = p.join(
          previousLease.rootPath,
          previousLease.relativePath,
        );
        File(p.join(profileDir, 'Cookies')).writeAsStringSync('existing state');
        var probes = 0;
        final step = EnsureChromeSessionStep(
          stateRegistry: stateRegistry,
          liveness: FakeLiveness(realIdentityPid: pid),
          spec: const BrowserSessionSpec(
            binaryPath: binaryPath,
            debugPort: 9336,
            profilePersistence: ProfilePersistence.persistent,
          ),
          pollInterval: const Duration(milliseconds: 1),
          probe: (final url) async => ++probes == 1 ? null : readyBody,
          startProcess: (final exe, final args) async {
            expect(args[1], '--user-data-dir=$profileDir');
            return FakeSessionProcess(10);
          },
        );

        final result = await step.run(ctx(temp), PipelineState());

        expect(result.ok, isTrue, reason: result.error);
        expect(
          File(p.join(profileDir, 'Cookies')).readAsStringSync(),
          'existing state',
        );
        final states = await stateRegistry.inspect();
        expect(states.leases, hasLength(1));
        expect(states.leases.single.id, previousLease.id);
      },
    );

    test('probe never answers → timeout failure names the exact remedy, '
        'spawned process stopped identity-verified (ADR-0018)', () async {
      final processes = <FakeSessionProcess>[];
      final liveness = FakeLiveness(token: 'tok-1717');
      final leaseDir = Directory.systemTemp.createTempSync('oka_lease_t_');
      addTearDown(() {
        if (leaseDir.existsSync()) leaseDir.deleteSync(recursive: true);
      });
      final registry = ProcessLeaseRegistry(leaseDir, liveness: liveness);
      final step = EnsureChromeSessionStep(
        stateRegistry: stateRegistry,
        spec: const BrowserSessionSpec(
          binaryPath: '/opt/chrome-wrong',
          debugPort: 9444,
          bootTimeout: Duration(milliseconds: 150),
        ),
        pollInterval: const Duration(milliseconds: 10),
        killGrace: const Duration(milliseconds: 5),
        probe: (final url) async => null,
        startProcess: (final exe, final args) async {
          final process = FakeSessionProcess(1717);
          processes.add(process);
          return process;
        },
        liveness: liveness,
        leaseRegistry: registry,
      );
      final state = PipelineState();
      final result = await step.run(ctx(temp), state);

      expect(result.ok, isFalse);
      final error = result.error!;
      expect(
        error,
        contains(
          'did not answer CDP at '
          'http://127.0.0.1:9444/json/version within 0s',
        ),
      );
      // The exact remedy, not a bare timeout.
      expect(error, contains('Remedies:'));
      expect(error, contains('/opt/chrome-wrong'));
      expect(error, contains('set debugPort explicitly'));
      expect(error, contains('headless: false'));
      // ADR-0018 problem A: the half-booted browser is stopped via the
      // held process handle — never left behind.
      expect(
        processes.single.killed,
        isTrue,
        reason: 'a half-booted browser must never be left behind',
      );
      expect(liveness.killed, [
        1717,
      ], reason: 'force rung of the graceful→force ladder');
      // The lease is cleaned up on the failure path.
      expect(await registry.list(), isEmpty);
      expect(state[step.handleArtifact.id], isNull);
    });

    test(
      'missing spawn PID token uses the process handle and clears intent only after stop',
      () async {
        final liveness = FakeLiveness(unidentifiablePids: const {1818});
        final registry = ProcessLeaseRegistry(
          Directory(p.join(temp.path, '.process-leases')),
          liveness: liveness,
        );
        final process = FakeSessionProcess(
          1818,
          onKill: () => liveness.alive = false,
        );
        var probes = 0;
        final step = EnsureChromeSessionStep(
          stateRegistry: stateRegistry,
          spec: const BrowserSessionSpec(
            binaryPath: '/opt/chrome',
            debugPort: 9445,
            bootTimeout: Duration(milliseconds: 10),
          ),
          pollInterval: const Duration(milliseconds: 1),
          killGrace: const Duration(milliseconds: 5),
          probe: (final url) async {
            probes++;
            return null;
          },
          startProcess: (final exe, final args) async => process,
          liveness: liveness,
          leaseRegistry: registry,
        );

        final result = await step.run(ctx(temp), PipelineState());

        expect(result.ok, isFalse);
        expect(
          result.error,
          contains('process identity token could not be verified'),
        );
        expect(result.error, contains('The process was stopped'));
        expect(probes, 1, reason: 'identity failure aborts before readiness');
        expect(process.killed, isTrue);
        expect(
          liveness.killed,
          isEmpty,
          reason: 'a missing identity token forbids signaling by pid',
        );
        expect(
          await registry.list(),
          isEmpty,
          reason: 'an unverifiable process is never written as a process lease',
        );
        final leases = (await stateRegistry.inspect()).leases;
        expect(leases, hasLength(1));
        expect(leases.single.metadata['process_snapshot_required'], isFalse);
        expect(leases.single.processPid, isNull);
      },
    );

    test(
      'unverified handle compensation leaves the durable process expectation',
      () async {
        final liveness = FakeLiveness(unidentifiablePids: const {1819});
        final registry = ProcessLeaseRegistry(
          Directory(p.join(temp.path, '.process-leases')),
          liveness: liveness,
        );
        final process = FakeSessionProcess(1819);
        final step = EnsureChromeSessionStep(
          stateRegistry: stateRegistry,
          spec: const BrowserSessionSpec(
            binaryPath: '/opt/chrome',
            debugPort: 9446,
            bootTimeout: Duration(milliseconds: 10),
          ),
          pollInterval: const Duration(milliseconds: 1),
          killGrace: const Duration(milliseconds: 5),
          probe: (final url) async => null,
          startProcess: (final exe, final args) async => process,
          liveness: liveness,
          leaseRegistry: registry,
        );

        final result = await step.run(ctx(temp), PipelineState());

        expect(result.ok, isFalse);
        expect(
          result.error,
          contains('process identity token could not be verified'),
        );
        expect(result.error, contains('not verified stopped'));
        expect(process.killed, isTrue);
        expect(await registry.list(), isEmpty);
        expect(
          (await stateRegistry.inspect())
              .leases
              .single
              .metadata['process_snapshot_required'],
          isTrue,
          reason: 'unverified compensation must remain recoverable',
        );
      },
    );

    test('starter throws → actionable failure naming binaryPath', () async {
      final step = EnsureChromeSessionStep(
        stateRegistry: stateRegistry,
        spec: const BrowserSessionSpec(binaryPath: '/does/not/exist'),
        probe: (final url) async => null,
        startProcess: (final exe, final args) async =>
            throw FileSystemException('No such file or directory', exe),
      );
      final result = await step.run(ctx(temp), PipelineState());
      expect(result.ok, isFalse);
      expect(result.error, contains('Failed to start "/does/not/exist"'));
      expect(result.error, contains('provisioning is deferred'));
      final states = await stateRegistry.inspect();
      expect(states.leases, hasLength(1));
      expect(
        states.leases.single.metadata['process_snapshot_required'],
        isFalse,
      );
    });

    test('starter Error clears its pre-spawn marker too', () async {
      final step = EnsureChromeSessionStep(
        stateRegistry: stateRegistry,
        spec: const BrowserSessionSpec(binaryPath: '/does/not/exist'),
        probe: (final url) async => null,
        startProcess: (final exe, final args) async =>
            throw StateError('starter failed'),
      );

      final result = await step.run(ctx(temp), PipelineState());

      expect(result.ok, isFalse);
      expect(result.error, contains('Failed to start "/does/not/exist"'));
      final states = await stateRegistry.inspect();
      expect(states.leases, hasLength(1));
      expect(
        states.leases.single.metadata['process_snapshot_required'],
        isFalse,
      );
    });

    test('fail-closed: invalid spec fails before any process is touched '
        '(ADR-0017 §3)', () async {
      var spawns = 0;
      var probes = 0;
      final step = EnsureChromeSessionStep(
        spec: const BrowserSessionSpec(
          binaryPath: binaryPath,
          launchFlags: ['--user-data-dir=/evil'],
          debugProtocol: DebugProtocol.webdriver,
        ),
        probe: (final url) async {
          probes++;
          return null;
        },
        startProcess: (final exe, final args) async {
          spawns++;
          return FakeSessionProcess(1);
        },
      );
      final result = await step.run(ctx(temp), PipelineState());
      expect(result.ok, isFalse);
      expect(spawns, 0);
      expect(probes, 0);
      expect(result.error, contains('fail-closed'));
      expect(result.error, contains('collides with the oka-owned flag'));
      expect(result.error, contains('Chrome speaks CDP only'));
    });
  });

  group('StopChromeSessionStep', () {
    test('kills only the recorded pid and retains the profile for '
        'verified state reconciliation', () async {
      final killed = <int>[];
      final profileDir = Directory.systemTemp.createTempSync(
        'oka_chrome_teardown_',
      );
      addTearDown(() {
        if (profileDir.existsSync()) profileDir.deleteSync(recursive: true);
      });

      final state = PipelineState();
      state['session-chrome-main-pid'] = 4242;
      state['session-chrome-main-profile-dir'] = profileDir.path;

      final liveness = FakeLiveness();
      final registry = ProcessLeaseRegistry.forProject(
        temp.path,
        liveness: liveness,
      );
      await registry.upsert(
        ProcessLease(
          id: 'chrome-main',
          pid: 4242,
          kind: 'chrome-session',
          identity: const {processLeasePidTokenKey: 'tok-1'},
          scope: LeaseScope.ephemeral,
          ownership: LeaseOwnership.owned,
          ownerCmd: 'test',
          startedAt: DateTime.utc(2026),
          stopHint: const LeaseStopHint(tool: 'kill', args: ['4242']),
        ),
      );
      final step = StopChromeSessionStep(
        liveness: liveness,
        leaseRegistry: registry,
        killProcess: (final pidValue) {
          killed.add(pidValue);
          liveness.alive = false;
          return true;
        },
      );
      final result = await step.run(ctx(temp), state);

      expect(result.ok, isTrue, reason: result.error);
      expect(killed, [4242]);
      expect(
        profileDir.existsSync(),
        isTrue,
        reason: 'teardown does not bypass state ownership and use checks',
      );
    });

    test(
      'missing or mismatched lease never authorizes an artifact PID',
      () async {
        final profile = Directory('${temp.path}/protected-profile')
          ..createSync();
        final host = FakeLiveness();
        final registry = ProcessLeaseRegistry.forProject(
          temp.path,
          liveness: host,
        );
        final killed = <int>[];
        final state = PipelineState()
          ..[chromeSessionPidArtifactId('main')] = 4242
          ..[chromeSessionProfileDirArtifactId('main')] = profile.path;
        final step = StopChromeSessionStep(
          liveness: host,
          leaseRegistry: registry,
          killProcess: (pid) {
            killed.add(pid);
            return true;
          },
        );
        expect((await step.run(ctx(temp), state)).ok, isFalse);
        await registry.upsert(
          ProcessLease(
            id: 'chrome-main',
            pid: 5555,
            kind: 'chrome-session',
            identity: const {processLeasePidTokenKey: 'tok-1'},
            scope: LeaseScope.ephemeral,
            ownership: LeaseOwnership.owned,
            ownerCmd: 'test',
            startedAt: DateTime.utc(2026),
            stopHint: const LeaseStopHint(tool: 'kill', args: ['5555']),
          ),
        );
        expect((await step.run(ctx(temp), state)).ok, isFalse);
        expect(killed, isEmpty);
        expect(profile.existsSync(), isTrue);
        expect(await registry.read('chrome-main'), isNotNull);
      },
    );

    test(
      'explicit external PID uses verification and preserves profile data',
      () async {
        final profile = Directory('${temp.path}/external-profile')
          ..createSync();
        final host = FakeLiveness();
        final registry = ProcessLeaseRegistry.forProject(
          temp.path,
          liveness: host,
        );
        final state = PipelineState()
          ..[chromeSessionProfileDirArtifactId('main')] = profile.path;
        final step = StopChromeSessionStep(
          pid: 4242,
          liveness: host,
          leaseRegistry: registry,
          killProcess: (_) {
            host.alive = false;
            return true;
          },
        );
        expect((await step.run(ctx(temp), state)).ok, isTrue);
        expect(profile.existsSync(), isTrue);
      },
    );

    test('fails actionably when nothing was recorded', () async {
      final result = await StopChromeSessionStep(
        sessionName: 'ghost',
      ).run(ctx(temp), PipelineState());
      expect(result.ok, isFalse);
      expect(result.error, contains('No chrome session "ghost" recorded'));
      expect(result.error, contains('A reused session records no pid'));
    });

    test('borrowed lease is refused and its profile is retained', () async {
      final profile = Directory('${temp.path}/borrowed-profile')
        ..createSync(recursive: true);
      final liveness = FakeLiveness();
      final registry = ProcessLeaseRegistry(
        Directory('${temp.path}/leases'),
        liveness: liveness,
      );
      await registry.upsert(
        ProcessLease(
          id: 'chrome-main',
          pid: 4242,
          kind: 'chrome-session',
          identity: const {
            processLeasePidTokenKey: 'tok-1',
            'profile_dir': 'borrowed-profile',
          },
          scope: LeaseScope.ephemeral,
          ownership: LeaseOwnership.borrowed,
          ownerCmd: 'external chrome',
          startedAt: DateTime.utc(2026, 9, 22),
          stopHint: const LeaseStopHint(tool: 'kill', args: ['4242']),
        ),
      );
      final state = PipelineState()
        ..[chromeSessionPidArtifactId('main')] = 4242
        ..[chromeSessionProfileDirArtifactId('main')] = profile.path;
      final step = StopChromeSessionStep(
        liveness: liveness,
        leaseRegistry: registry,
        killProcess: (_) => true,
      );
      final result = await step.run(ctx(temp), state);
      expect(result.ok, isFalse);
      expect(result.error, contains('borrowed'));
      expect(profile.existsSync(), isTrue);
      expect(await registry.read('chrome-main'), isNotNull);
      expect(liveness.killed, isEmpty);
    });
  });

  group('ADR-0018 leases', () {
    late Directory temp;
    late FakeLiveness liveness;
    late ProcessLeaseRegistry registry;
    late SessionStateRegistry stateRegistry;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('oka_chrome_lease_');
      liveness = FakeLiveness();
      registry = ProcessLeaseRegistry(
        Directory('${temp.path}/.oka_cache/processes'),
        liveness: liveness,
      );
      stateRegistry = SessionStateRegistry(
        Directory(
          p.join(temp.resolveSymbolicLinksSync(), '.session-state-registry'),
        ),
        bootId: 'test-boot',
      );
    });
    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('spawn writes an owned lease (kind, cdp_port identity, token, '
        'scope from profilePersistence)', () async {
      final processes = <FakeSessionProcess>[];
      var probes = 0;
      final step = EnsureChromeSessionStep(
        stateRegistry: stateRegistry,
        spec: const BrowserSessionSpec(
          binaryPath: '/opt/chrome',
          debugPort: 9223,
        ),
        pollInterval: const Duration(milliseconds: 10),
        probe: (final url) async =>
            probes++ == 0 ? null : '{"Browser": "Chrome/126"}',
        startProcess: (final exe, final args) async {
          final process = FakeSessionProcess(1717);
          processes.add(process);
          return process;
        },
        liveness: liveness,
        leaseRegistry: registry,
      );
      final r = await step.run(ctx(temp), PipelineState());
      expect(r.ok, isTrue, reason: r.error);
      expect(processes, hasLength(1), reason: 'must spawn, not reuse');
      final lease = await registry.read(step.leaseId);
      expect(lease, isNotNull);
      expect(lease!.pid, 1717);
      expect(lease.kind, 'chrome-session');
      expect(lease.ownership, LeaseOwnership.owned);
      expect(
        lease.scope,
        LeaseScope.ephemeral,
        reason: 'ephemeral profile → ephemeral session',
      );
      expect(lease.identity['cdp_port'], '9223');
      expect(lease.identity['session_name'], 'main');
      expect(
        lease.identity['profile_dir'],
        startsWith(
          p.join(Directory(temp.path).resolveSymbolicLinksSync(), '.oka_cache'),
        ),
      );
      expect(lease.identity[processLeasePidTokenKey], 'tok-1');
      expect(lease.stopHint.tool, 'kill');
      expect(lease.stopHint.args, ['1717']);
      expect(liveness.killed, isEmpty, reason: 'success path never signals');
    });

    test('persistent profile → persistent scope', () async {
      final step = EnsureChromeSessionStep(
        stateRegistry: stateRegistry,
        spec: const BrowserSessionSpec(
          binaryPath: '/opt/chrome',
          debugPort: 9223,
          profilePersistence: ProfilePersistence.persistent,
        ),
        pollInterval: const Duration(milliseconds: 10),
        probe: (final url) async => '{"Browser": "Chrome/126"}',
        liveness: liveness,
        leaseRegistry: registry,
      );
      final r = await step.run(ctx(temp), PipelineState());
      expect(r.ok, isTrue, reason: r.error);
      expect((await registry.read(step.leaseId))?.scope, LeaseScope.persistent);
    });

    test(
      'reuse path flips an owned lease to borrowed, kills nothing',
      () async {
        final step = EnsureChromeSessionStep(
          stateRegistry: stateRegistry,
          spec: const BrowserSessionSpec(
            binaryPath: '/opt/chrome',
            debugPort: 9223,
          ),
          pollInterval: const Duration(milliseconds: 10),
          probe: (final url) async => '{"Browser": "Chrome/126"}',
          liveness: liveness,
          leaseRegistry: registry,
        );
        // A prior run (another terminal) owned this session.
        await registry.upsert(
          ProcessLease(
            id: 'chrome-main',
            pid: 1717,
            kind: 'chrome-session',
            identity: const {'cdp_port': '9223'},
            scope: LeaseScope.ephemeral,
            ownership: LeaseOwnership.owned,
            ownerCmd: 'oka run chrome-session',
            startedAt: DateTime.now().toUtc(),
            stopHint: const LeaseStopHint(tool: 'kill', args: ['1717']),
          ),
        );
        final r = await step.run(ctx(temp), PipelineState());
        expect(r.ok, isTrue, reason: r.error);
        final lease = await registry.read('chrome-main');
        expect(lease!.ownership, LeaseOwnership.borrowed);
        expect(lease.identity['cdp_port'], '9223');
        expect(liveness.killed, isEmpty);
      },
    );

    test('reused session with no prior lease records one as borrowed '
        '(pid 0)', () async {
      final step = EnsureChromeSessionStep(
        stateRegistry: stateRegistry,
        spec: const BrowserSessionSpec(
          binaryPath: '/opt/chrome',
          debugPort: 9223,
        ),
        pollInterval: const Duration(milliseconds: 10),
        probe: (final url) async => '{"Browser": "Chrome/126"}',
        liveness: liveness,
        leaseRegistry: registry,
      );
      final r = await step.run(ctx(temp), PipelineState());
      expect(r.ok, isTrue, reason: r.error);
      final lease = await registry.read('chrome-main');
      expect(lease!.ownership, LeaseOwnership.borrowed);
      expect(lease.pid, 0);
    });

    test(
      'recycled pid on the timeout path → NOT signaled, lease dropped',
      () async {
        // Token changes AFTER the lease records it (pid-recycling
        // simulation): spawn → token captured (tok-1) → lease written → the
        // OS recycles the pid → the gate then sees tok-RECYCLED. Probe call
        // #1 is the reuse check; readiness probes (#2+) run after the lease
        // write, so the token flip happens there.
        var probes = 0;
        final step = EnsureChromeSessionStep(
          stateRegistry: stateRegistry,
          spec: const BrowserSessionSpec(
            binaryPath: '/opt/chrome-wrong',
            debugPort: 9444,
            bootTimeout: Duration(milliseconds: 120),
          ),
          pollInterval: const Duration(milliseconds: 10),
          killGrace: const Duration(milliseconds: 5),
          probe: (final url) async {
            // Probe call #1 is the reuse check (before spawn + lease write);
            // readiness probes (#2+) run after the lease is recorded — flip
            // the token there to simulate pid recycling mid-readiness.
            if (probes++ == 0) return null;
            liveness.token = 'tok-RECYCLED';
            return null;
          },
          startProcess: (final exe, final args) async =>
              FakeSessionProcess(1717),
          liveness: liveness,
          leaseRegistry: registry,
        );
        final r = await step.run(ctx(temp), PipelineState());
        expect(r.ok, isFalse);
        expect(r.error, isNot(contains('was stopped')));
        expect(
          liveness.killed,
          isEmpty,
          reason: 'a recycled pid belongs to an innocent process',
        );
        expect(
          await registry.list(),
          isEmpty,
          reason: 'the provably-stale record is dropped',
        );
      },
    );
  });

  group('ADR-0018 L1 teardown composition', () {
    const ctx = BuildContext(
      projectPath: '/tmp/x',
      buildDir: '/tmp/x/.oka_cache/build',
      mode: BuildMode.debug,
      config: OkaConfig.empty,
      cacheDir: '/tmp/x/.oka_cache',
    );

    test('ephemeral session → unconditional teardown step (ADR-0017 §5)', () {
      const target = ChromeSessionTarget(
        spec: BrowserSessionSpec(binaryPath: '/opt/chrome'),
      );
      final steps = target.compileTeardown(ctx);
      expect(steps, hasLength(1));
      expect(steps.single.name, 'stop-chrome-session');
    });

    test('persistent session → survives the run (no teardown step)', () {
      const target = ChromeSessionTarget(
        spec: BrowserSessionSpec(
          binaryPath: '/opt/chrome',
          profilePersistence: ProfilePersistence.persistent,
        ),
      );
      expect(target.compileTeardown(ctx), isEmpty);
    });
  });
}
