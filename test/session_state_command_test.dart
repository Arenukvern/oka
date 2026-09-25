import 'dart:convert';
import 'dart:io';

import 'package:oka/src/cli/session_state_command.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _CliHandle {
  const _CliHandle(this.path);

  final String path;
}

final class _CliPlanner implements SessionStatePlanner<_CliHandle> {
  const _CliPlanner(this.root);

  final String root;

  @override
  String get id => 'cli-planner';

  @override
  SessionStatePlan<_CliHandle> plan(final SessionStateRequest request) =>
      SessionStatePlan(
        logicalResourceKey: 'cli:${request.sessionName}',
        namespace: SessionStateNamespace.project,
        retention: SessionStateRetention.persistent,
        processScope: LeaseScope.persistent,
        ownership: SessionStateOwnership.oka,
        acquisitionMode: SessionStateAcquisitionMode.created,
        resourceKind: SessionStateResourceKind.directory,
        rootPath: root,
        relativePath: 'profiles/${request.sessionName}',
        handle: _CliHandle(p.join(root, 'profiles', request.sessionName)),
      );
}

final class _CliSource implements SessionStateSource<_CliHandle> {
  @override
  String get id => 'cli-source';

  @override
  Future<_CliHandle> restore(final SessionStateLease lease) async =>
      _CliHandle(p.join(lease.rootPath, lease.relativePath));
}

final class _CliProvision implements SessionStateProvisionStep<_CliHandle> {
  @override
  String get id => 'cli-provision';

  @override
  Set<Artifact<Object>> get requires => const {};

  @override
  Set<Artifact<Object>> get provides => const {};

  @override
  Future<void> run(final SessionStateContext<_CliHandle> context) async {}
}

final class _CliUnused implements SessionStateInspector<_CliHandle> {
  @override
  String get id => 'cli-unused';

  @override
  Future<SessionStateFinding> inspect(
    final SessionStateContext<_CliHandle> context,
  ) async => const SessionStateFinding(
    inspectorId: 'cli-unused',
    use: SessionStateUse.unused,
    reason: 'not in use',
  );
}

final class _CliLiveness implements ProcessLiveness {
  int aliveChecks = 0;

  @override
  Future<bool> isAlive(final int processId) async {
    aliveChecks++;
    return processId == pid;
  }

  @override
  Future<String?> identityToken(final int processId) async =>
      processId == pid ? 'cli-current-owner' : null;

  @override
  Future<bool> kill(
    final int processId, {
    final Duration grace = const Duration(seconds: 3),
  }) async => false;
}

SessionStateWorkflow<_CliHandle> _cliWorkflow(final String root) =>
    SessionStateWorkflow(
      id: 'test.cli-profile',
      version: 1,
      plan: _CliPlanner(root),
      source: _CliSource(),
      provision: [_CliProvision()],
      inspectors: [_CliUnused()],
    );

void main() {
  late Directory temp;
  late SessionStateRegistry registry;

  setUp(() async {
    exitCode = 0;
    temp = await Directory.systemTemp.createTemp('oka-session-state-cli-');
    registry = SessionStateRegistry(
      Directory(p.join(await temp.resolveSymbolicLinks(), 'registry')),
      bootId: 'test-boot',
    );
  });

  tearDown(() async {
    exitCode = 0;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'list emits a structured JSON envelope without creating a lease',
    () async {
      final output = <String>[];
      final errors = <String>[];
      await SessionStateCommand(
        registry: registry,
        workflows: const [],
        output: output.add,
        errorOutput: errors.add,
      ).run(['list', '--json']);

      expect(errors, isEmpty);
      expect(exitCode, 0);
      final event = jsonDecode(output.single) as Map<String, Object?>;
      expect(event['scope'], 'session-state');
      expect(event['event'], 'session-state.inventory');
      expect((event['params']! as Map)['summary'], {
        'leases': 0,
        'registry_issues': 0,
      });
    },
  );

  test(
    'no-entrypoint reconciliation uses the injected liveness provider',
    () async {
      final root = Directory(p.join(temp.path, 'managed-root'));
      await root.create();
      final liveness = _CliLiveness();
      final workflow = _cliWorkflow(root.path);
      final lease =
          await SessionStateManager(
            registry: registry,
            liveness: liveness,
          ).acquire(
            workflow,
            SessionStateRequest(
              projectPath: temp.path,
              sessionName: 'liveness',
            ),
          );
      final output = <String>[];

      await SessionStateCommand(
        registry: registry,
        workflows: [workflow],
        liveness: liveness,
        output: output.add,
        errorOutput: (_) {},
      ).run(['close', lease.id, '--json']);

      expect(liveness.aliveChecks, greaterThan(0));
      final event = jsonDecode(output.single) as Map<String, Object?>;
      final params = event['params']! as Map<String, Object?>;
      final entries = params['entries']! as List;
      expect(
        (entries.single as Map<String, Object?>)['disposition'],
        'retained',
      );
    },
  );

  test(
    'forget is preview-only by default and removes only an absent resource record',
    () async {
      final now = DateTime.now().toUtc();
      const id = '00000000000000000000000000000001';
      await registry.create(
        SessionStateLease(
          id: id,
          workflowId: 'test.missing-state',
          workflowVersion: 1,
          logicalResourceKey: 'test:missing',
          namespace: SessionStateNamespace.project,
          retention: SessionStateRetention.ephemeral,
          processScope: LeaseScope.ephemeral,
          ownership: SessionStateOwnership.oka,
          acquisitionMode: SessionStateAcquisitionMode.created,
          phase: SessionStatePhase.ready,
          resourceKind: SessionStateResourceKind.directory,
          rootPath: await temp.resolveSymbolicLinks(),
          relativePath: 'profiles/missing',
          markerNonce: 'nonce',
          hostId: 'host',
          bootId: 'test-boot',
          ownerProject: temp.path,
          ownerPid: pid,
          ownerPidToken: 'token',
          createdAt: now,
          updatedAt: now,
        ),
      );

      final preview = <String>[];
      await SessionStateCommand(
        registry: registry,
        workflows: const [],
        output: preview.add,
        errorOutput: (_) {},
      ).run(['forget', id]);
      expect(exitCode, 0);
      expect(preview.join('\n'), contains('preview'));
      expect(preview.join('\n'), contains('reservation marker untouched'));
      expect((await registry.inspect()).leases, hasLength(1));

      final applied = <String>[];
      await SessionStateCommand(
        registry: registry,
        workflows: const [],
        output: applied.add,
        errorOutput: (_) {},
      ).run(['forget', id, '--apply', '--json']);

      final event = jsonDecode(applied.single) as Map<String, Object?>;
      expect(event['event'], 'session-state.forget');
      final params = event['params']! as Map<String, Object?>;
      final entries = params['entries']! as List<Object?>;
      final entry = entries.single! as Map<String, Object?>;
      expect(entry['disposition'], 'forgotten');
      expect((await registry.inspect()).leases, isEmpty);
    },
  );

  test(
    'close without --apply is a preview and unknown IDs are visible',
    () async {
      final output = <String>[];
      final errors = <String>[];
      await SessionStateCommand(
        registry: registry,
        workflows: const [],
        output: output.add,
        errorOutput: errors.add,
      ).run(['close', '00000000000000000000000000000000']);

      expect(output, isEmpty);
      expect(errors.single, contains('No session-state lease found'));
      expect(exitCode, 1);
    },
  );

  test('unknown IDs fail with JSON output as well as human output', () async {
    final output = <String>[];
    final errors = <String>[];
    await SessionStateCommand(
      registry: registry,
      workflows: const [],
      output: output.add,
      errorOutput: errors.add,
    ).run(['close', '00000000000000000000000000000000', '--json']);

    expect(exitCode, 1);
    expect(errors.single, contains('No session-state lease found'));
    final event = jsonDecode(output.single) as Map<String, Object?>;
    expect(event['event'], 'session-state.close');
    expect((event['params']! as Map)['entries'], isEmpty);
  });

  test('resume unknown ID fails with a JSON error event', () async {
    final output = <String>[];
    final errors = <String>[];
    await SessionStateCommand(
      registry: registry,
      workflows: const [],
      output: output.add,
      errorOutput: errors.add,
    ).run(['resume', '00000000000000000000000000000000', '--json']);

    expect(exitCode, 1);
    expect(errors, isEmpty);
    final event = jsonDecode(output.single) as Map<String, Object?>;
    expect(event['event'], 'session-state.resume');
    final params = event['params']! as Map<String, Object?>;
    expect(params['status'], 'error');
    expect(params['error'], contains('No session-state lease found'));
  });

  test('resume explicitly provisions a matching partial lease', () async {
    final workflow = _cliWorkflow(await temp.resolveSymbolicLinks());
    final liveness = _CliLiveness();
    final acquired =
        await SessionStateManager(
          registry: registry,
          liveness: liveness,
        ).acquire(
          workflow,
          SessionStateRequest(
            projectPath: temp.path,
            sessionName: 'cli-resume',
          ),
        );
    final partial = await registry.update(
      acquired.copyWith(phase: SessionStatePhase.partial),
      expectedGeneration: acquired.generation,
    );
    final output = <String>[];
    final errors = <String>[];

    await SessionStateCommand(
      registry: registry,
      workflows: [workflow],
      liveness: liveness,
      output: output.add,
      errorOutput: errors.add,
    ).run(['resume', partial.id, '--json']);

    expect(errors, isEmpty);
    final event = jsonDecode(output.single) as Map<String, Object?>;
    expect(event['event'], 'session-state.resume');
    final params = event['params']! as Map<String, Object?>;
    expect(params['error'], isNull);
    expect(params['status'], 'ready');
    expect(exitCode, 0);
    expect(params['lease_id'], partial.id);
    expect((await registry.read(partial.id))?.phase, SessionStatePhase.ready);

    final humanLease =
        await SessionStateManager(
          registry: registry,
          liveness: liveness,
        ).acquire(
          workflow,
          SessionStateRequest(
            projectPath: temp.path,
            sessionName: 'cli-resume-human',
          ),
        );
    final retryable = await registry.update(
      humanLease.copyWith(phase: SessionStatePhase.partial),
      expectedGeneration: humanLease.generation,
    );
    final humanOutput = <String>[];
    await SessionStateCommand(
      registry: registry,
      workflows: [workflow],
      liveness: liveness,
      output: humanOutput.add,
      errorOutput: errors.add,
    ).run(['resume', retryable.id]);
    expect(exitCode, 0);
    expect(humanOutput.single, contains('phase is ready'));
  });

  test('registry issues are reported in JSON and fail the command', () async {
    await registry.directory.create(recursive: true);
    await File(
      p.join(registry.directory.path, 'malformed.json'),
    ).writeAsString('{not-json');
    final output = <String>[];
    var commandExitCode = 0;

    await SessionStateCommand(
      registry: registry,
      workflows: const [],
      output: output.add,
      errorOutput: (_) {},
      setExitCode: (final value) => commandExitCode = value,
    ).run(['list', '--json']);

    expect(commandExitCode, 1);
    final event = jsonDecode(output.single) as Map<String, Object?>;
    final params = event['params']! as Map<String, Object?>;
    expect(params['summary'], containsPair('registry_issues', 1));
    expect(params['issues'], hasLength(1));
  });

  test(
    'reconcile accepts retained entries but explicit refused actions fail',
    () async {
      const id = '00000000000000000000000000000002';
      final now = DateTime.now().toUtc();
      await registry.create(
        SessionStateLease(
          id: id,
          workflowId: 'test.unavailable',
          workflowVersion: 1,
          logicalResourceKey: 'test:unavailable',
          namespace: SessionStateNamespace.project,
          retention: SessionStateRetention.ephemeral,
          processScope: LeaseScope.ephemeral,
          ownership: SessionStateOwnership.oka,
          acquisitionMode: SessionStateAcquisitionMode.created,
          phase: SessionStatePhase.ready,
          resourceKind: SessionStateResourceKind.directory,
          rootPath: await temp.resolveSymbolicLinks(),
          relativePath: 'profiles/unavailable',
          markerNonce: 'nonce',
          hostId: 'host',
          bootId: 'test-boot',
          ownerProject: temp.path,
          ownerPid: pid,
          ownerPidToken: 'token',
          createdAt: now,
          updatedAt: now,
        ),
      );

      final reconcileOutput = <String>[];
      await SessionStateCommand(
        registry: registry,
        workflows: const [],
        output: reconcileOutput.add,
        errorOutput: (_) {},
      ).run(['reconcile', '--apply']);
      expect(exitCode, 0);
      expect(reconcileOutput.join('\n'), contains('reconciliation applied'));
      expect(reconcileOutput.join('\n'), contains('1 retained'));
      expect(reconcileOutput.join('\n'), contains('same-user'));
      expect(
        reconcileOutput.join('\n'),
        isNot(contains('Apply was requested')),
      );

      final reconcileJson = <String>[];
      exitCode = 0;
      await SessionStateCommand(
        registry: registry,
        workflows: const [],
        output: reconcileJson.add,
        errorOutput: (_) {},
      ).run(['reconcile', '--apply', '--json']);
      expect(exitCode, 0);
      final reconcileEvent =
          jsonDecode(reconcileJson.single) as Map<String, Object?>;
      final reconcileParams = reconcileEvent['params']! as Map<String, Object?>;
      expect(reconcileParams['safety_notes'], contains(contains('same-user')));

      await SessionStateCommand(
        registry: registry,
        workflows: const [],
        output: (_) {},
        errorOutput: (_) {},
      ).run(['close', id]);
      expect(exitCode, 0);

      final closeOutput = <String>[];
      exitCode = 0;
      await SessionStateCommand(
        registry: registry,
        workflows: const [],
        output: closeOutput.add,
        errorOutput: (_) {},
      ).run(['close', id, '--apply']);
      expect(exitCode, 1);
      expect(closeOutput.join('\n'), contains('Apply was requested'));
      expect(closeOutput.join('\n'), contains('same-user'));

      await Directory(
        p.join(await temp.resolveSymbolicLinks(), 'profiles', 'unavailable'),
      ).create(recursive: true);
      final forgetOutput = <String>[];
      exitCode = 0;
      await SessionStateCommand(
        registry: registry,
        workflows: const [],
        output: forgetOutput.add,
        errorOutput: (_) {},
      ).run(['forget', id, '--apply']);
      expect(exitCode, 1);
      expect(forgetOutput.join('\n'), contains('retained'));
      expect(forgetOutput.join('\n'), isNot(contains('same-user')));
      expect((await registry.inspect()).leases, hasLength(1));
    },
  );
}
