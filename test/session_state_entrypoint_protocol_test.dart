import 'dart:convert';
import 'dart:io';

import 'package:oka/src/cli/session_state_entrypoint.dart';
import 'package:oka_core/oka_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _repoRoot = Directory.current.path;
const _protocolFramePrefix = '\x1eOKA_SESSION_STATE_V1:';

Map<String, Object?> _protocolResponse(final String stdout) {
  final frames = const LineSplitter()
      .convert(stdout)
      .where((final line) => line.startsWith(_protocolFramePrefix))
      .toList();
  if (frames.length != 1) {
    throw FormatException(
      'Expected one protocol frame, found ${frames.length}.',
    );
  }
  return (jsonDecode(frames.single.substring(_protocolFramePrefix.length))
          as Map)
      .cast<String, Object?>();
}

void main() {
  late Directory sandbox;
  late Directory home;
  late SessionStateRegistry registry;
  late SessionStateHostIdentity hostIdentity;
  late String cliPath;

  Future<ProcessResult> entrypointCall(final Map<String, Object?> request) =>
      Process.run(
        'dart',
        [
          'run',
          'tool/oka_pipeline.dart',
          '--oka-session-state',
          jsonEncode(request),
        ],
        workingDirectory: sandbox.path,
        environment: {...Platform.environment, 'HOME': home.path},
      );

  Future<ProcessResult> cli(final List<String> args) => Process.run(
    'dart',
    ['run', cliPath, ...args],
    workingDirectory: sandbox.path,
    environment: {...Platform.environment, 'HOME': home.path},
  );

  setUp(() async {
    sandbox = Directory(
      p.join(
        _repoRoot,
        '.oka_cache',
        'session_state_protocol_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    home = Directory(p.join(sandbox.path, 'home'));
    await Directory(p.join(sandbox.path, 'tool')).create(recursive: true);
    await home.create(recursive: true);
    File(
      p.join(_repoRoot, 'test/fixtures/session_state_protocol_entrypoint.dart'),
    ).copySync(p.join(sandbox.path, 'tool/oka_pipeline.dart'));
    registry = SessionStateRegistry.forCurrentUser(homeDirectory: home.path);
    hostIdentity = await registry.hostIdentity();
    cliPath = p.relative(
      p.join(_repoRoot, 'packages/oka/bin/oka.dart'),
      from: sandbox.path,
    );
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  SessionStateLease lease({
    required final String id,
    required final String workflowId,
    required final int workflowVersion,
    required final String rootPath,
  }) {
    final now = DateTime.now().toUtc();
    return SessionStateLease(
      id: id,
      workflowId: workflowId,
      workflowVersion: workflowVersion,
      logicalResourceKey: 'protocol:$id',
      namespace: SessionStateNamespace.project,
      retention: SessionStateRetention.ephemeral,
      processScope: LeaseScope.ephemeral,
      ownership: SessionStateOwnership.oka,
      acquisitionMode: SessionStateAcquisitionMode.created,
      phase: SessionStatePhase.ready,
      resourceKind: SessionStateResourceKind.directory,
      rootPath: rootPath,
      relativePath: 'state/$id',
      markerNonce: 'test-nonce',
      hostId: hostIdentity.hostId,
      bootId: hostIdentity.bootId,
      ownerProject: sandbox.path,
      ownerPid: 99999999,
      ownerPidToken: 'unknown-owner',
      createdAt: now,
      updatedAt: now,
    );
  }

  test(
    'session-state CLI executes the workflow composed by the entrypoint',
    () async {
      const id = '00000000000000000000000000000001';
      await registry.create(
        lease(
          id: id,
          workflowId: 'test.project-session-state',
          workflowVersion: 7,
          rootPath: sandbox.path,
        ),
      );

      final process = await cli(['session-state', 'inspect', id, '--json']);
      expect(process.exitCode, 0, reason: '${process.stderr}');
      final event =
          jsonDecode(process.stdout as String) as Map<String, Object?>;
      expect(event['event'], 'session-state.inspect');
      final params = event['params']! as Map<String, Object?>;
      final entries = params['entries']! as List;
      final findings =
          (entries.single as Map<String, Object?>)['findings']! as List;
      expect(
        findings
            .map((final finding) => (finding as Map<String, Object?>)['reason'])
            .toList(),
        contains('inspected by the project entrypoint workflow'),
      );
    },
  );

  test(
    'protocol version fails closed and missing workflows stay unknown',
    () async {
      final wrongVersion = await entrypointCall({
        'protocol_version': 999,
        'operation': 'reconcile',
      });
      expect(wrongVersion.exitCode, isNonZero);
      expect(
        wrongVersion.stderr,
        contains('Oka session-state protocol: FormatException: Unsupported'),
      );
      final rawOutput = wrongVersion.stdout as String;
      expect(rawOutput, contains('ordinary project stdout before okaRun'));
      expect(rawOutput, contains('ordinary project stdout after okaRun'));
      final versionResponse = _protocolResponse(rawOutput);
      expect(
        versionResponse['schema_version'],
        'oka.session-state.protocol.v1',
      );
      expect(versionResponse['status'], 'error');
      expect(versionResponse['error'], contains('Unsupported'));

      const id = '00000000000000000000000000000002';
      await registry.create(
        lease(
          id: id,
          workflowId: 'test.not-composed',
          workflowVersion: 1,
          rootPath: sandbox.path,
        ),
      );
      final missingWorkflow = await entrypointCall({
        'protocol_version': 1,
        'operation': 'inspect',
        'lease_id': id,
      });
      expect(missingWorkflow.exitCode, 0, reason: '${missingWorkflow.stderr}');
      final missingOutput = missingWorkflow.stdout as String;
      expect(missingOutput, contains('ordinary project stdout before okaRun'));
      expect(missingOutput, contains('ordinary project stdout after okaRun'));
      final missingResponse = _protocolResponse(missingOutput);
      expect(missingResponse['status'], 'ok');
      final missingResult = missingResponse['result']! as Map<String, Object?>;
      final missingEntries = missingResult['entries']! as List;
      final missingEntry = missingEntries.single as Map<String, Object?>;
      expect(missingEntry['disposition'], 'retained');
      expect(
        (missingEntry['findings']! as List).cast<Map<String, Object?>>().map(
          (final finding) => finding['reason'],
        ),
        contains(
          'workflow test.not-composed@1 is not composed in this invocation.',
        ),
      );

      const wrongWorkflowVersionId = '00000000000000000000000000000005';
      await registry.create(
        lease(
          id: wrongWorkflowVersionId,
          workflowId: 'test.project-session-state',
          workflowVersion: 8,
          rootPath: sandbox.path,
        ),
      );
      final wrongWorkflowVersion = await entrypointCall({
        'protocol_version': 1,
        'operation': 'inspect',
        'lease_id': wrongWorkflowVersionId,
      });
      expect(
        wrongWorkflowVersion.exitCode,
        0,
        reason: '${wrongWorkflowVersion.stderr}',
      );
      final wrongWorkflowVersionResponse = _protocolResponse(
        wrongWorkflowVersion.stdout as String,
      );
      expect(wrongWorkflowVersionResponse['status'], 'ok');
      final versionResult =
          wrongWorkflowVersionResponse['result']! as Map<String, Object?>;
      final versionEntries = versionResult['entries']! as List;
      final versionEntry = versionEntries.single as Map<String, Object?>;
      expect(versionEntry['disposition'], 'retained');
      expect(
        (versionEntry['findings']! as List).cast<Map<String, Object?>>().map(
          (final finding) => finding['reason'],
        ),
        contains(
          'workflow test.project-session-state@8 is not composed in this invocation.',
        ),
      );
    },
  );

  test(
    'doctor delegates inspection to the discoverable project entrypoint',
    () async {
      const id = '00000000000000000000000000000004';
      await registry.create(
        lease(
          id: id,
          workflowId: 'test.not-composed',
          workflowVersion: 1,
          rootPath: sandbox.path,
        ),
      );

      final process = await cli(['doctor']);
      final output = process.stdout as String;
      expect(output, contains('[Managed Session State]'));
      expect(
        output,
        contains('retained: workflow test.not-composed@1 is unavailable'),
      );
    },
  );

  test(
    'CLI delegates close and rejects resume without the exact workflow version',
    () async {
      const closeId = '00000000000000000000000000000006';
      await registry.create(
        lease(
          id: closeId,
          workflowId: 'test.project-session-state',
          workflowVersion: 7,
          rootPath: sandbox.path,
        ),
      );
      final close = await cli(['session-state', 'close', closeId, '--json']);
      expect(close.exitCode, 0, reason: '${close.stderr}');
      final closeEvent =
          jsonDecode(close.stdout as String) as Map<String, Object?>;
      expect(closeEvent['event'], 'session-state.close');
      final closeParams = closeEvent['params']! as Map<String, Object?>;
      final closeEntries = closeParams['entries']! as List;
      expect(
        (closeEntries.single as Map<String, Object?>)['disposition'],
        'eligible',
      );

      const resumeId = '00000000000000000000000000000007';
      await registry.create(
        lease(
          id: resumeId,
          workflowId: 'test.project-session-state',
          workflowVersion: 8,
          rootPath: sandbox.path,
        ),
      );
      final resume = await cli(['session-state', 'resume', resumeId, '--json']);
      expect(resume.exitCode, isNonZero);
      final resumeEvent =
          jsonDecode(resume.stdout as String) as Map<String, Object?>;
      expect(resumeEvent['event'], 'session-state.resume');
      final resumeParams = resumeEvent['params']! as Map<String, Object?>;
      expect(resumeParams['status'], 'error');
      expect(
        resumeParams['error'],
        contains('No unique composed workflow matches'),
      );
    },
  );

  test('CLI delegates resume to the exact project-composed workflow', () async {
    const id = '0000000000000000000000000000000a';
    final partial =
        lease(
          id: id,
          workflowId: 'test.project-session-state',
          workflowVersion: 7,
          rootPath: sandbox.path,
        ).copyWith(
          phase: SessionStatePhase.partial,
          reservationMarkerAdjacent: true,
        );
    await registry.create(partial);
    final reservation = File(partial.reservationMarkerPath);
    await reservation.parent.create(recursive: true);
    await reservation.writeAsString(
      jsonEncode({
        'id': partial.id,
        'nonce': partial.markerNonce,
        'host_id': partial.hostId,
      }),
    );

    final process = await cli(['session-state', 'resume', id, '--json']);

    expect(process.exitCode, 0, reason: '${process.stderr}');
    final event = jsonDecode(process.stdout as String) as Map<String, Object?>;
    expect(event['event'], 'session-state.resume');
    final params = event['params']! as Map<String, Object?>;
    expect(params['status'], 'ready');
    expect(params['workflow_id'], 'test.project-session-state');
    expect(params['workflow_version'], 7);
    expect((await registry.read(id))?.phase, SessionStatePhase.ready);
    expect(
      await Directory(p.join(sandbox.path, partial.relativePath)).exists(),
      isTrue,
    );
  });

  test('forget remains preview-only until delegated --apply', () async {
    const id = '00000000000000000000000000000003';
    final missingRoot = p.join(sandbox.path, 'absent-root');
    await registry.create(
      lease(
        id: id,
        workflowId: 'test.project-session-state',
        workflowVersion: 7,
        rootPath: missingRoot,
      ),
    );

    final preview = await cli(['session-state', 'forget', id, '--json']);
    expect(preview.exitCode, 0, reason: '${preview.stderr}');
    final previewEvent =
        jsonDecode(preview.stdout as String) as Map<String, Object?>;
    final previewParams = previewEvent['params']! as Map<String, Object?>;
    expect(previewParams['applied'], isFalse);
    expect(await registry.read(id), isNotNull);

    final applied = await cli([
      'session-state',
      'forget',
      id,
      '--json',
      '--apply',
    ]);
    expect(applied.exitCode, 0, reason: '${applied.stderr}');
    final appliedEvent =
        jsonDecode(applied.stdout as String) as Map<String, Object?>;
    final appliedParams = appliedEvent['params']! as Map<String, Object?>;
    expect(appliedParams['applied'], isTrue);
    expect(await registry.read(id), isNull);
  });

  test(
    'project protocol rejects missing, duplicate, and malformed frames',
    () async {
      Future<FormatException> callWithMode(final String mode) async {
        try {
          await runProjectSessionState(
            projectPath: sandbox.path,
            request: {'operation': 'reconcile', '_fixture_mode': mode},
          );
        } on FormatException catch (error) {
          return error;
        }
        throw StateError('Expected $mode to fail closed.');
      }

      expect(
        (await callWithMode('missing-frame')).message,
        contains('no session-state protocol frame'),
      );
      expect(
        (await callWithMode('duplicate-frame')).message,
        contains('expected exactly one'),
      );
      expect(
        (await callWithMode('malformed-frame')).message,
        contains('invalid session-state response'),
      );
    },
  );
}
