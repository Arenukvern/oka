import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_web/oka_web.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _ScriptedLiveness implements ProcessLiveness {
  const _ScriptedLiveness({required this.alive});

  final bool alive;

  @override
  Future<bool> isAlive(final int pid) async => alive;

  @override
  Future<String?> identityToken(final int pid) async => 'token-$pid';

  @override
  Future<bool> kill(
    final int pid, {
    final Duration grace = const Duration(seconds: 3),
  }) async => false;
}

SessionStateContext<ChromeProfileHandle> _context(
  final String profilePath, {
  final int? processPid,
  final String? processPidToken,
  final int ownerPid = 1,
  final SessionStateAcquisitionMode acquisitionMode =
      SessionStateAcquisitionMode.created,
  final Map<String, Object?> metadata = const {},
}) {
  final now = DateTime.utc(2026);
  return SessionStateContext(
    handle: ChromeProfileHandle(profilePath),
    lease: SessionStateLease(
      id: '00000000000000000000000000000001',
      workflowId: 'test.chrome-profile',
      workflowVersion: 1,
      logicalResourceKey: 'chrome-profile:test',
      namespace: SessionStateNamespace.project,
      retention: SessionStateRetention.ephemeral,
      processScope: LeaseScope.ephemeral,
      ownership: SessionStateOwnership.oka,
      acquisitionMode: acquisitionMode,
      phase: SessionStatePhase.ready,
      resourceKind: SessionStateResourceKind.directory,
      rootPath: p.dirname(profilePath),
      relativePath: p.basename(profilePath),
      markerNonce: 'nonce',
      hostId: 'host',
      bootId: 'boot',
      ownerProject: p.dirname(profilePath),
      ownerPid: ownerPid,
      ownerPidToken: 'owner-token',
      processPid: processPid,
      processPidToken: processPidToken,
      metadata: metadata,
      createdAt: now,
      updatedAt: now,
    ),
  );
}

void main() {
  group('ChromeProfileUseInspector', () {
    late Directory temp;
    late Directory profile;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('oka-chrome-profile-test-');
      profile = Directory(p.join(temp.path, 'profile'));
      await profile.create();
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('an absent singleton lock is affirmative unused evidence', () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final finding = await const ChromeProfileUseInspector().inspect(
        _context(profile.path),
      );

      expect(finding.use, SessionStateUse.unused);
      expect(finding.reason, contains('SingletonLock is absent'));
    });

    test('a live singleton owner is busy', () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final lock = Link(p.join(profile.path, 'SingletonLock'));
      await lock.create('${Platform.localHostname}-4242');
      final finding = await const ChromeProfileUseInspector(
        liveness: _ScriptedLiveness(alive: true),
      ).inspect(_context(profile.path));

      expect(finding.use, SessionStateUse.busy);
      expect(finding.reason, contains('still alive'));
    });

    test(
      'a dead singleton PID is unknown rather than proof of inactivity',
      () async {
        if (!Platform.isLinux && !Platform.isMacOS) return;
        final lock = Link(p.join(profile.path, 'SingletonLock'));
        await lock.create('${Platform.localHostname}-4242');
        final finding = await const ChromeProfileUseInspector(
          liveness: _ScriptedLiveness(alive: false),
        ).inspect(_context(profile.path));

        expect(finding.use, SessionStateUse.unknown);
        expect(finding.reason, contains('detached child'));
      },
    );

    test(
      'a dead lock matching the durable process snapshot is still unknown',
      () async {
        if (!Platform.isLinux && !Platform.isMacOS) return;
        final lock = Link(p.join(profile.path, 'SingletonLock'));
        await lock.create('${Platform.localHostname}-4242');
        final finding =
            await const ChromeProfileUseInspector(
              liveness: _ScriptedLiveness(alive: false),
            ).inspect(
              _context(
                profile.path,
                processPid: 4242,
                processPidToken: 'token-4242',
              ),
            );

        expect(finding.use, SessionStateUse.unknown);
        expect(finding.reason, contains('cleanup is not authorized'));
      },
    );

    test('a dead local lock permits launch but not cleanup', () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final lock = Link(p.join(profile.path, 'SingletonLock'));
      await lock.create('${Platform.localHostname}-4242');
      final finding =
          await const ChromeProfileLaunchInspector(
            liveness: _ScriptedLiveness(alive: false),
          ).inspect(
            _context(
              profile.path,
              processPid: 4242,
              processPidToken: 'token-4242',
            ),
          );

      expect(finding.use, SessionStateUse.unused);
      expect(finding.reason, contains('not cleanup evidence'));
      expect(finding.details['authority'], 'launch-only');
    });

    test(
      'Windows permits only the first launch of a new profile without a lock',
      () async {
        if (!Platform.isWindows) return;
        final fresh = _context(
          profile.path,
          ownerPid: pid,
          metadata: const {'process_snapshot_required': false},
        );
        final launch = await const ChromeProfileLaunchInspector().inspect(
          fresh,
        );
        expect(launch.use, SessionStateUse.unused);
        expect(launch.reason, contains('first launch'));

        final reused = SessionStateContext(
          handle: fresh.handle,
          lease: fresh.lease.copyWith(
            acquisitionMode: SessionStateAcquisitionMode.reused,
          ),
        );
        final reusedLaunch = await const ChromeProfileLaunchInspector().inspect(
          reused,
        );
        expect(reusedLaunch.use, SessionStateUse.unknown);

        final cleanup = await const ChromeProfileUseInspector().inspect(fresh);
        expect(cleanup.use, SessionStateUse.unknown);
      },
    );

    test(
      'a dead singleton without a matching process snapshot is unknown',
      () async {
        if (!Platform.isLinux && !Platform.isMacOS) return;
        await Link(
          p.join(profile.path, 'SingletonLock'),
        ).create('${Platform.localHostname}-4242');

        final finding = await const ChromeProfileLaunchInspector(
          liveness: _ScriptedLiveness(alive: false),
        ).inspect(_context(profile.path, processPid: 4343));

        expect(finding.use, SessionStateUse.unknown);
        expect(
          finding.reason,
          contains('does not match a verified process snapshot'),
        );
      },
    );

    test(
      'reconciliation retains profile and Cookies when a dead SingletonLock remains',
      () async {
        if (!Platform.isLinux && !Platform.isMacOS) return;
        final projectPath = await temp.resolveSymbolicLinks();
        final registry = SessionStateRegistry(
          Directory(p.join(projectPath, '.session-state-registry')),
          bootId: 'test-boot',
        );
        const liveness = _ScriptedLiveness(alive: false);
        final manager = SessionStateManager(
          registry: registry,
          liveness: liveness,
        );
        final lease = await manager.acquire(
          chromeProfileStateWorkflow,
          SessionStateRequest(
            projectPath: projectPath,
            sessionName: 'main',
            metadata: {
              'state_root': projectPath,
              'relative_path': p.posix.join(
                '.oka_cache',
                'session-state',
                'chrome',
                'main',
              ),
              'state_retention': SessionStateRetention.ephemeral.label,
              'process_scope': LeaseScope.ephemeral.label,
              'process_snapshot_required': true,
            },
          ),
        );
        final managedProfile = p.join(lease.rootPath, lease.relativePath);
        final cookies = File(p.join(managedProfile, 'Cookies'));
        await cookies.writeAsString('saved login state');
        await manager.expectProcess(lease.id);
        await manager.attachProcess(
          leaseId: lease.id,
          processLeaseId: 'chrome-main',
          processPid: 4242,
          processPidToken: 'token-4242',
        );
        await Link(
          p.join(managedProfile, 'SingletonLock'),
        ).create('${Platform.localHostname}-4242');

        final report = await SessionStateReconciler(
          registry: registry,
          workflows: const [chromeProfileStateWorkflow],
          liveness: liveness,
        ).reconcile(apply: true);

        expect(report.entries, hasLength(1));
        expect(
          report.entries.single.disposition,
          SessionStateDisposition.retained,
        );
        expect(
          report.entries.single.reason,
          contains('cleanup is not authorized'),
        );
        expect(Directory(managedProfile).existsSync(), isTrue);
        expect(cookies.readAsStringSync(), 'saved login state');
        expect(await registry.read(lease.id), isNotNull);
      },
    );
  });
}
