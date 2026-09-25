import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_web/oka_web.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  final requested =
      Platform.environment['OKA_REQUIRE_REAL_CHROME_SMOKE'] == '1';
  final supportedHost = Platform.isLinux || Platform.isMacOS;

  test(
    'real Chrome profile can launch, stop, and reconcile',
    () async {
      final binaryPath =
          Platform.environment['OKA_CHROME_BINARY'] ??
          (Platform.isMacOS
              ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
              : 'google-chrome');
      if (p.isAbsolute(binaryPath)) {
        expect(
          await File(binaryPath).exists(),
          isTrue,
          reason: 'Set OKA_CHROME_BINARY to an installed Chromium executable.',
        );
      }

      final scratch = await Directory.systemTemp.createTemp(
        'oka-real-chrome-session-',
      );
      final temp = Directory(await scratch.resolveSymbolicLinks());
      final project = Directory(p.join(temp.path, 'project'));
      await project.create();
      final buildDir = p.join(project.path, '.oka_cache', 'build', 'debug');
      final context = BuildContext(
        projectPath: project.path,
        buildDir: buildDir,
        mode: BuildMode.debug,
        config: OkaConfig.empty,
      );
      const liveness = HostProcessLiveness();
      final stateRegistry = SessionStateRegistry(
        Directory(p.join(temp.path, 'session-states')),
      );
      final processRegistry = ProcessLeaseRegistry.forProject(
        project.path,
        liveness: liveness,
      );
      final state = PipelineState();
      const workflow = chromeProfileStateWorkflow;
      final ensure = EnsureChromeSessionStep(
        spec: BrowserSessionSpec(binaryPath: binaryPath),
        pollInterval: const Duration(milliseconds: 100),
        liveness: liveness,
        leaseRegistry: processRegistry,
        stateRegistry: stateRegistry,
      );
      try {
        final started = await ensure.run(context, state);
        expect(started.ok, isTrue, reason: started.error);
        expect(state[chromeSessionPidArtifactId('main')], isA<int>());
        final profiles = (await stateRegistry.inspect()).leases;
        expect(profiles, hasLength(1));
        final profilePath = p.join(
          profiles.single.rootPath,
          profiles.single.relativePath,
        );
        expect(await Directory(profilePath).exists(), isTrue);

        final stopped = await StopChromeSessionStep(
          liveness: liveness,
          leaseRegistry: processRegistry,
        ).run(context, state);
        expect(stopped.ok, isTrue, reason: stopped.error);

        // Reconciliation runs after the Oka invocation that acquired the
        // session exits. Model that boundary with a real short-lived process
        // identity rather than claiming the current test process is gone.
        final previousOwner = await Process.start('sleep', ['30']);
        final previousOwnerToken = await liveness.identityToken(
          previousOwner.pid,
        );
        expect(previousOwnerToken, isNotNull);
        previousOwner.kill();
        await previousOwner.exitCode;
        final lease = (await stateRegistry.inspect()).leases.single;
        await stateRegistry.update(
          lease.copyWith(
            ownerPid: previousOwner.pid,
            ownerPidToken: previousOwnerToken,
          ),
          expectedGeneration: lease.generation,
        );

        final report = await SessionStateReconciler(
          registry: stateRegistry,
          workflows: [workflow],
        ).reconcile(apply: true);
        expect(report.entries, hasLength(1));
        expect(
          report.entries.single.disposition,
          SessionStateDisposition.disposed,
          reason: report.entries.single.reason,
        );
        expect(await Directory(profilePath).exists(), isFalse);
      } finally {
        final processId = state[chromeSessionPidArtifactId('main')];
        if (processId is int && await liveness.isAlive(processId)) {
          await liveness.kill(processId);
        }
        if (await temp.exists()) await temp.delete(recursive: true);
      }
    },
    skip: !requested
        ? 'Set OKA_REQUIRE_REAL_CHROME_SMOKE=1 to launch an installed browser.'
        : !supportedHost
        ? 'Destructive session-state cleanup is report-only on this host.'
        : null,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
