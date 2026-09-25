import 'dart:convert';

import 'package:oka_core/oka_core.dart';

const _protocolFramePrefix = '\x1eOKA_SESSION_STATE_V1:';

final class _Handle {
  const _Handle();
}

final class _Planner implements SessionStatePlanner<_Handle> {
  const _Planner();

  @override
  String get id => 'protocol-planner';

  @override
  SessionStatePlan<_Handle> plan(final SessionStateRequest request) =>
      SessionStatePlan(
        logicalResourceKey: 'protocol:${request.sessionName}',
        namespace: SessionStateNamespace.project,
        retention: SessionStateRetention.ephemeral,
        processScope: LeaseScope.ephemeral,
        ownership: SessionStateOwnership.oka,
        acquisitionMode: SessionStateAcquisitionMode.created,
        resourceKind: SessionStateResourceKind.directory,
        rootPath: request.projectPath,
        relativePath: '.protocol-state/${request.sessionName}',
        handle: const _Handle(),
      );
}

final class _Source implements SessionStateSource<_Handle> {
  const _Source();

  @override
  String get id => 'protocol-source';

  @override
  Future<_Handle> restore(final SessionStateLease lease) async =>
      const _Handle();
}

final class _Inspector implements SessionStateInspector<_Handle> {
  const _Inspector();

  @override
  String get id => 'protocol-inspector';

  @override
  Future<SessionStateFinding> inspect(
    final SessionStateContext<_Handle> context,
  ) async => const SessionStateFinding(
    inspectorId: 'protocol-inspector',
    use: SessionStateUse.unused,
    reason: 'inspected by the project entrypoint workflow',
    details: {'implementation': 'project-code'},
  );
}

const _workflow = SessionStateWorkflow<_Handle>(
  id: 'test.project-session-state',
  version: 7,
  plan: _Planner(),
  source: _Source(),
  inspectors: [_Inspector()],
);

Future<void> main(final List<String> args) async {
  print('ordinary project stdout before okaRun');
  final request = jsonDecode(args[1]) as Map<String, dynamic>;
  final fixtureMode = request.remove('_fixture_mode');
  if (fixtureMode == 'missing-frame') {
    print('ordinary project stdout after okaRun');
    return;
  }
  if (fixtureMode == 'malformed-frame') {
    print('${_protocolFramePrefix}not-json');
    print('ordinary project stdout after okaRun');
    return;
  }

  await okaRun([
    args[0],
    jsonEncode(request),
  ], oka: const Oka(pipelines: [], sessionStateWorkflows: [_workflow]));
  if (fixtureMode == 'duplicate-frame') {
    final duplicateResponse = <String, Object?>{
      'schema_version': 'oka.session-state.protocol.v1',
      'protocol_version': 1,
      'status': 'ok',
      'result': <String, Object?>{},
    };
    print('$_protocolFramePrefix${jsonEncode(duplicateResponse)}');
  }
  print('ordinary project stdout after okaRun');
}
