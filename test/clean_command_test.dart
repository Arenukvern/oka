import 'dart:io';

import 'package:oka/src/cli/clean_command.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Directory project;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('oka-clean-');
    project = Directory(p.join(temp.path, 'project'));
    await Directory(p.join(project.path, '.oka_cache')).create(recursive: true);
    await File(
      p.join(project.path, '.oka_cache', 'build-output'),
    ).writeAsString('keep unless safe');
    exitCode = 0;
  });

  tearDown(() async {
    exitCode = 0;
    await temp.delete(recursive: true);
  });

  test(
    'refuses cache deletion when the session-state registry has issues',
    () async {
      final output = <String>[];
      final command = CleanCommand(
        currentDirectory: project.path,
        environment: {'HOME': temp.path},
        inspectSessionStates: () async => const SessionStateRegistrySnapshot(
          issues: [
            SessionStateRegistryIssue(
              path: '/registry/bad.json',
              message: 'unreadable record',
            ),
          ],
        ),
        output: output.add,
      );

      await command.run([]);

      expect(exitCode, 1);
      expect(
        File(p.join(project.path, '.oka_cache', 'build-output')).existsSync(),
        isTrue,
      );
      expect(output.join('\n'), contains('unreadable record'));
      expect(output.join('\n'), contains('Remedies:'));
      expect(output.join('\n'), contains('oka session-state list --json'));
      expect(
        output.join('\n'),
        contains('Do not delete session-state resource data'),
      );
    },
  );

  test(
    'cleans unrelated cache data while preserving an active state resource',
    () async {
      final resource = p.join(project.path, '.oka_cache', 'session', 'profile');
      await Directory(resource).create(recursive: true);
      final lease = _lease(
        p.join(project.path, '.oka_cache'),
        'session/profile',
      );
      final reservation = File(lease.reservationMarkerPath);
      await reservation.parent.create(recursive: true);
      await reservation.writeAsString('reservation');
      final output = <String>[];
      final command = CleanCommand(
        currentDirectory: project.path,
        environment: {'HOME': temp.path},
        inspectSessionStates: () async =>
            SessionStateRegistrySnapshot(leases: [lease]),
        output: output.add,
      );

      await command.run([]);

      expect(exitCode, 0);
      expect(Directory(resource).existsSync(), isTrue);
      expect(
        File(p.join(project.path, '.oka_cache', 'build-output')).existsSync(),
        isFalse,
      );
      expect(reservation.existsSync(), isTrue);
      expect(output.join('\n'), contains('Preserved protected session-state'));
    },
  );

  test('clean preserves a persisted disposing quarantine path', () async {
    final quarantine = Directory(
      p.join(project.path, '.oka_cache', 'session', '.oka-quarantine-test'),
    );
    await quarantine.create(recursive: true);
    final payload = File(p.join(quarantine.path, 'profile-data'));
    await payload.writeAsString('keep while disposal is in progress');
    final lease = _lease(
      p.join(project.path, '.oka_cache'),
      'session/profile',
      phase: SessionStatePhase.disposing,
      quarantineRelativePath: 'session/.oka-quarantine-test',
    );
    final output = <String>[];
    final command = CleanCommand(
      currentDirectory: project.path,
      environment: {'HOME': temp.path},
      inspectSessionStates: () async =>
          SessionStateRegistrySnapshot(leases: [lease]),
      output: output.add,
    );

    await command.run([]);

    expect(exitCode, 0, reason: output.join('\n'));
    expect(payload.existsSync(), isTrue);
    expect(
      File(p.join(project.path, '.oka_cache', 'build-output')).existsSync(),
      isFalse,
    );
    expect(output.join('\n'), contains('same-user filesystem races'));
  });

  test(
    'clean fails closed for a symlinked persisted quarantine path',
    () async {
      final external = Directory(p.join(temp.path, 'external'))..createSync();
      final linked = Link(p.join(project.path, '.oka_cache', 'linked'));
      await linked.create(external.path);
      final command = CleanCommand(
        currentDirectory: project.path,
        environment: {'HOME': temp.path},
        inspectSessionStates: () async => SessionStateRegistrySnapshot(
          leases: [
            _lease(
              p.join(project.path, '.oka_cache'),
              'session/profile',
              phase: SessionStatePhase.disposing,
              quarantineRelativePath: 'linked/.oka-quarantine-test',
            ),
          ],
        ),
        output: (_) {},
      );

      await command.run([]);

      expect(exitCode, 1);
      expect(
        File(p.join(project.path, '.oka_cache', 'build-output')).existsSync(),
        isTrue,
      );

      exitCode = 0;
      final traversalCommand = CleanCommand(
        currentDirectory: project.path,
        environment: {'HOME': temp.path},
        inspectSessionStates: () async => SessionStateRegistrySnapshot(
          leases: [
            _lease(
              p.join(project.path, '.oka_cache'),
              'session/profile',
              phase: SessionStatePhase.disposing,
              quarantineRelativePath: '../outside-quarantine',
            ),
          ],
        ),
        output: (_) {},
      );
      await traversalCommand.run([]);

      expect(exitCode, 1);
      expect(
        File(p.join(project.path, '.oka_cache', 'build-output')).existsSync(),
        isTrue,
      );
    },
  );

  test(
    'active session state outside the cache is never deleted by clean',
    () async {
      final stateOutsideCache = p.join(temp.path, 'persistent-state');
      await Directory(stateOutsideCache).create();
      final command = CleanCommand(
        currentDirectory: project.path,
        environment: {'HOME': temp.path},
        inspectSessionStates: () async => SessionStateRegistrySnapshot(
          leases: [_lease(stateOutsideCache, 'profile')],
        ),
        output: (_) {},
      );

      await command.run([]);

      expect(exitCode, 0);
      expect(
        Directory(p.join(project.path, '.oka_cache')).existsSync(),
        isFalse,
      );
      expect(Directory(stateOutsideCache).existsSync(), isTrue);
    },
  );

  test(
    'clean preserves a persistent profile reservation while removing unrelated cache data',
    () async {
      final profile = p.join(project.path, '.oka', 'build', 'chrome-profiles');
      await Directory(profile).create(recursive: true);
      final lease = _lease(
        project.path,
        p.relative(profile, from: project.path),
      );
      final reservation = File(lease.reservationMarkerPath);
      await reservation.parent.create(recursive: true);
      await reservation.writeAsString('reservation');
      final command = CleanCommand(
        currentDirectory: project.path,
        environment: {'HOME': temp.path},
        inspectSessionStates: () async =>
            SessionStateRegistrySnapshot(leases: [lease]),
        output: (_) {},
      );

      await command.run([]);

      expect(exitCode, 0);
      expect(
        File(p.join(project.path, '.oka_cache', 'build-output')).existsSync(),
        isFalse,
      );
      expect(reservation.existsSync(), isTrue);
      expect(Directory(profile).existsSync(), isTrue);
    },
  );
}

SessionStateLease _lease(
  String root,
  String relative, {
  SessionStatePhase phase = SessionStatePhase.ready,
  String? quarantineRelativePath,
}) {
  final now = DateTime.utc(2026);
  return SessionStateLease(
    id: '00000000000000000000000000000000',
    workflowId: 'fixture',
    workflowVersion: 1,
    logicalResourceKey: 'fixture-resource',
    namespace: SessionStateNamespace.project,
    retention: SessionStateRetention.persistent,
    processScope: LeaseScope.ephemeral,
    ownership: SessionStateOwnership.oka,
    acquisitionMode: SessionStateAcquisitionMode.created,
    phase: phase,
    resourceKind: SessionStateResourceKind.directory,
    rootPath: root,
    relativePath: relative,
    markerNonce: 'marker',
    hostId: 'host',
    bootId: 'boot',
    ownerProject: root,
    ownerPid: 1,
    ownerPidToken: 'pid-token',
    createdAt: now,
    updatedAt: now,
    quarantineRelativePath: quarantineRelativePath,
  );
}
