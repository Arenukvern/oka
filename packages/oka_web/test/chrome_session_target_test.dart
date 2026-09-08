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
  FakeSessionProcess(this.pid);

  @override
  final int pid;

  bool killed = false;

  @override
  bool kill() {
    killed = true;
    return true;
  }
}

BuildContext ctx(final Directory temp) => BuildContext(
      projectPath: temp.path,
      buildDir: p.join(temp.path, '.oka', 'build'),
      mode: BuildMode.debug,
      config: OkaConfig.empty,
    );

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('oka_chrome_target_'));

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
      const body = '{"Browser":"Chrome/126.0.6478.126",'
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

    test('debugProtocol mismatch fails closed naming the accepted surface',
        () {
      for (final protocol in DebugProtocol.values) {
        if (protocol == DebugProtocol.cdp) continue;
        final issues = chromeSessionIssues(specWithProtocol(protocol));
        expect(issues, hasLength(1), reason: protocol.label);
        expect(issues.single, contains('DebugProtocol.cdp'));
        expect(issues.single, contains('Chrome speaks CDP only'));
      }
    });

    test('spec-level issues flow through', () {
      final issues =
          chromeSessionIssues(const BrowserSessionSpec(binaryPath: ''));
      expect(issues, hasLength(1));
      expect(issues.single, contains('binaryPath is empty'));
    });
  });

  group('ChromeSessionTarget', () {
    const spec = BrowserSessionSpec(binaryPath: '/usr/bin/google-chrome');

    test('name passes ADR-0015 target-name validation', () {
      expect(validateTargetName(const ChromeSessionTarget(spec: spec).name),
          isNull);
      expect(
        const ChromeSessionTarget(spec: spec).name,
        'chrome-session',
      );
    });

    test('compile produces ensure-chrome-session; chain validates; '
        'artifacts follow the ADR-0017 §2 convention', () {
      const target = ChromeSessionTarget(spec: spec);
      final steps = target.compile(ctx(temp));
      expect(steps.map((final s) => s.name).toList(), ['ensure-chrome-session']);
      expect(Pipeline(steps).validate(), isNull);

      final step = steps.single as EnsureChromeSessionStep;
      expect(step.handleArtifact.id, 'session-chrome-main-handle');
      expect(step.portArtifact.id, 'session-chrome-main-cdp-port');
      expect(step.provides.map((final a) => a.id).toSet(),
          {step.handleArtifact.id, step.portArtifact.id});
      expect(
        target.description,
        contains('session-chrome-main-handle'),
      );
    });

    test('sessionName namespaces the artifact ids', () {
      final step = EnsureChromeSessionStep(
        spec: spec,
        sessionName: 'showcase',
      );
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

    test('reuse path: a port already answering CDP is reused, never '
        'spawned against (idempotent, ADR-0017 §1)', () async {
      var probes = 0;
      Uri? probedUrl;
      var spawns = 0;
      final step = EnsureChromeSessionStep(
        spec: const BrowserSessionSpec(
          binaryPath: binaryPath,
          debugPort: 9222,
        ),
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
      expect(
        state[step.handleArtifact.id],
        'http://127.0.0.1:9222',
      );
      expect(state[step.portArtifact.id], 9222);
      // A reused session records no pid — it is not ours to stop.
      expect(state[step.pidArtifact.id], isNull);
      expect(state[step.profileDirArtifact.id], isNull);
      expect(result.data['reused'], 'true');
    });

    test('spawn path: probe answers after N attempts → artifacts + '
        'ephemeral profile dir recorded', () async {
      var probes = 0;
      final spawned = <List<String>>[];
      final processes = <FakeSessionProcess>[];
      final step = EnsureChromeSessionStep(
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

    test('spawn path: persistent profile lives under the build dir, not '
        'system temp (ADR-0017 §5)', () async {
      var probes = 0;
      String? profileDir;
      var spawns = 0;
      final step = EnsureChromeSessionStep(
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
      final result = await step.run(ctx(temp), state);

      expect(result.ok, isTrue, reason: result.error);
      expect(spawns, 1, reason: 'reuse probe missed → exactly one spawn');
      expect(probes, 2);
      expect(profileDir, startsWith(p.join(temp.path, '.oka', 'build')));
      // Persistent dirs are never recorded for teardown.
      expect(state[step.profileDirArtifact.id], isNull);
    });

    test('probe never answers → timeout failure names the exact remedy, '
        'spawned process killed', () async {
      final processes = <FakeSessionProcess>[];
      final killedPids = <int>[];
      final step = EnsureChromeSessionStep(
        spec: const BrowserSessionSpec(
          binaryPath: '/opt/chrome-wrong',
          debugPort: 9444,
          bootTimeout: Duration(milliseconds: 150),
        ),
        pollInterval: const Duration(milliseconds: 10),
        probe: (final url) async => null,
        startProcess: (final exe, final args) async {
          final process = FakeSessionProcess(1717);
          processes.add(process);
          return process;
        },
        killProcess: (final pidValue) {
          killedPids.add(pidValue);
          return true;
        },
      );
      final state = PipelineState();
      final result = await step.run(ctx(temp), state);

      expect(result.ok, isFalse);
      final error = result.error!;
      expect(error, contains('did not answer CDP at '
          'http://127.0.0.1:9444/json/version within 0s'));
      // The exact remedy, not a bare timeout.
      expect(error, contains('Remedies:'));
      expect(error, contains('/opt/chrome-wrong'));
      expect(error, contains('set debugPort explicitly'));
      expect(error, contains('headless: false'));
      expect(killedPids, [1717],
          reason: 'a half-booted browser must never be left behind');
      expect(state[step.handleArtifact.id], isNull);
    });

    test('starter throws → actionable failure naming binaryPath', () async {
      final step = EnsureChromeSessionStep(
        spec: const BrowserSessionSpec(binaryPath: '/does/not/exist'),
        probe: (final url) async => null,
        startProcess: (final exe, final args) async =>
            throw FileSystemException('No such file or directory', exe),
      );
      final result = await step.run(ctx(temp), PipelineState());
      expect(result.ok, isFalse);
      expect(result.error, contains('Failed to start "/does/not/exist"'));
      expect(result.error, contains('provisioning is deferred'));
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
    test('kills only the recorded pid and deletes only the recorded '
        'ephemeral profile dir', () async {
      final killed = <int>[];
      final profileDir =
          Directory.systemTemp.createTempSync('oka_chrome_teardown_');
      addTearDown(() {
        if (profileDir.existsSync()) profileDir.deleteSync(recursive: true);
      });

      final state = PipelineState();
      state['session-chrome-main-pid'] = 4242;
      state['session-chrome-main-profile-dir'] = profileDir.path;

      final step = StopChromeSessionStep(
        killProcess: (final pidValue) {
          killed.add(pidValue);
          return true;
        },
      );
      final result = await step.run(ctx(temp), state);

      expect(result.ok, isTrue, reason: result.error);
      expect(killed, [4242]);
      expect(profileDir.existsSync(), isFalse,
          reason: 'ephemeral profile dir is deleted');
    });

    test('fails actionably when nothing was recorded', () async {
      final result = await StopChromeSessionStep(
        sessionName: 'ghost',
      ).run(ctx(temp), PipelineState());
      expect(result.ok, isFalse);
      expect(result.error, contains('No chrome session "ghost" recorded'));
      expect(result.error, contains('A reused session records no pid'));
    });
  });
}
