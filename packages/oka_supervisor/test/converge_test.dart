import 'dart:io';

import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:resource_composition/resource_composition.dart';
import 'package:test/test.dart';

/// A [FakeProvider]-shaped seam whose observation and start error are
/// mutable between converges, with call recording.
final class ScriptedProvider implements ResourceProvider {
  ScriptedProvider({
    this.observation = const Observation(state: ResourceState.unknown),
    this.outputs = const <String, Object?>{},
  });

  Observation observation;
  Object? startError;
  final Map<String, Object?> outputs;

  final starts = <StartRequest>[];
  final stops = <ResourceRef>[];
  int _pid = 4200;

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    readinessProbe: true,
    attach: true,
    durableIdentity: true,
  );

  @override
  Future<StartReport> start(final StartRequest request) async {
    starts.add(request);
    if (startError != null) {
      // ignore: only_throw_errors — scripted by the test.
      throw startError!;
    }
    final pid = ++_pid;
    return StartReport(
      ref: ResourceRef(
        componentId: request.component.id,
        handle: 'fake://${request.component.id}',
        pid: pid,
        identityToken: 'token-$pid',
      ),
      outputs: ResolvedOutputs(outputs),
    );
  }

  @override
  Future<Observation> inspect(final ResourceRef ref) async => observation;

  @override
  Future<StopReport> stop(
    final ResourceRef ref, {
    required final Duration grace,
  }) async {
    stops.add(ref);
    return const StopReport(
      disposition: StopDisposition.stopped,
      cause: TerminalCause.exited,
    );
  }

  @override
  Future<Observation> reconcile(final ResourceRef ref) async => observation;
}

void main() {
  late Directory temp;
  late MachineRegistry registry;
  late CollectingEvidenceSink sink;
  final base = DateTime.utc(2026, 10, 9, 12);
  late DateTime now;

  Supervisor makeSupervisor() => Supervisor(
    projectRoot: '${temp.path}/project',
    registry: registry,
    clock: () => now,
  );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('oka-converge-test');
    registry = MachineRegistry(root: '${temp.path}/supervisor');
    sink = CollectingEvidenceSink();
    now = base;
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test('service happy path: start, record, then converge to ready', () async {
    final api = ScriptedProvider();
    final supervisor = makeSupervisor();
    const desired = DesiredState(
      specs: [ComponentSpec(id: 'api', providerName: 'sh')],
    );

    final first = await supervisor.converge(
      desired: desired,
      factory: (final name) => api,
      evidence: sink,
    );
    expect(first.started, 1);
    final record = registry.read(supervisor.scope, 'api');
    expect(record, isNotNull);
    expect(record!.epoch, 1);
    expect(record.killPolicy, KillPolicy.spawned);
    expect(record.pid, isNotNull);
    expect(record.revisionHash, isNotEmpty);
    expect(
      sink.events.map((final e) => e.kind.wire),
      containsAll(['componentStarting', 'componentReady']),
    );

    api.observation = const Observation(state: ResourceState.ready);
    final second = await supervisor.converge(
      desired: desired,
      factory: (final name) => api,
      evidence: sink,
    );
    expect(second.started, 0);
    expect(second.plan.actions, isEmpty);
    expect(second.plan.findings.single.code, 'ready');
    expect(api.starts, hasLength(1));
    expect(
      sink.events.whereType<SupervisorFindingEvent>().map((final e) => e.code),
      contains('ready'),
    );
  });

  test('dry run plans without touching the world', () async {
    final api = ScriptedProvider();
    const desired = DesiredState(
      specs: [ComponentSpec(id: 'api', providerName: 'sh')],
    );
    final report = await makeSupervisor().converge(
      desired: desired,
      factory: (final name) => api,
      evidence: sink,
      apply: false,
    );
    expect(report.plan.startCount, 1);
    expect(api.starts, isEmpty);
    expect(registry.snapshot(makeSupervisor().scope).records, isEmpty);
  });

  test(
    'crash restarts within budget, then gives up, then revision resets',
    () async {
      final api = ScriptedProvider();
      final supervisor = makeSupervisor();
      const desired = DesiredState(
        specs: [
          ComponentSpec(
            id: 'api',
            providerName: 'sh',
            policy: SupervisionPolicy(maxRestarts: 2),
          ),
        ],
      );
      ResourceProvider factory(final String name) => api;

      await supervisor.converge(
        desired: desired,
        factory: factory,
        evidence: sink,
      );

      api.observation = const Observation(
        state: ResourceState.crashed,
        cause: TerminalCause.exited,
      );
      final restartOne = await supervisor.converge(
        desired: desired,
        factory: factory,
        evidence: sink,
      );
      expect(restartOne.restarted, 1);
      expect(api.stops, hasLength(1));
      var record = registry.read(supervisor.scope, 'api')!;
      expect(record.restartCount, 1);
      expect(record.epoch, 2);

      // Drive the ledger to the limit directly (the third crash).
      registry.upsert(
        record.copyWith(restartCount: 2),
        scope: supervisor.scope,
      );
      final gaveUp = await supervisor.converge(
        desired: desired,
        factory: factory,
        evidence: sink,
      );
      expect(gaveUp.plan.actions, isEmpty);
      expect(gaveUp.plan.findings.map((final f) => f.code), contains('giveUp'));
      expect(api.starts, hasLength(2));

      // The revision bump is the reset: a changed declaration restarts.
      const bumped = DesiredState(
        specs: [
          ComponentSpec(
            id: 'api',
            providerName: 'sh',
            policy: SupervisionPolicy(maxRestarts: 2, revision: 2),
          ),
        ],
      );
      final afterBump = await supervisor.converge(
        desired: bumped,
        factory: factory,
        evidence: sink,
      );
      expect(afterBump.restarted, 1);
      record = registry.read(supervisor.scope, 'api')!;
      // The fresh budget starts at one consumed slot: this restart itself.
      expect(record.restartCount, 1);
      expect(record.epoch, 3);
    },
  );

  test('unowned processes are never signaled', () async {
    final api = ScriptedProvider();
    final supervisor = makeSupervisor();
    final scope = supervisor.scope;
    const spec = ComponentSpec(id: 'api', providerName: 'sh');
    registry.upsert(
      SupervisorRecord(
        componentId: 'api',
        providerName: 'sh',
        shape: 'service',
        revisionHash: spec.revisionHash,
        epoch: 1,
        killPolicy: KillPolicy.none,
        startedAt: base,
        restartCount: 0,
        windowStartedAt: base,
        trigger: 'none',
        pid: 999,
      ),
      scope: scope,
    );
    api.observation = const Observation(
      state: ResourceState.crashed,
      cause: TerminalCause.exited,
    );
    ResourceProvider factory(final String name) => api;
    final report = await supervisor.converge(
      desired: const DesiredState(specs: [spec]),
      factory: factory,
      evidence: sink,
    );
    expect(report.plan.actions, isEmpty);
    expect(api.stops, isEmpty);
    expect(api.starts, isEmpty);
    expect(report.plan.findings.map((final f) => f.code), contains('unowned'));
    // The foreign record stays — observe-only means no registry surgery.
    expect(registry.read(scope, 'api'), isNotNull);
  });

  test('orphans are findings; their records are preserved', () async {
    final api = ScriptedProvider();
    final supervisor = makeSupervisor();
    final scope = supervisor.scope;
    registry.upsert(
      SupervisorRecord(
        componentId: 'ghost',
        providerName: 'sh',
        shape: 'service',
        revisionHash: 'whatever',
        epoch: 1,
        killPolicy: KillPolicy.none,
        startedAt: base,
        restartCount: 0,
        windowStartedAt: base,
        trigger: 'none',
        pid: 123,
      ),
      scope: scope,
    );
    final report = await supervisor.converge(
      desired: const DesiredState(
        specs: [ComponentSpec(id: 'api', providerName: 'sh')],
      ),
      factory: (final name) => api,
      evidence: sink,
    );
    expect(report.started, 1);
    expect(
      report.plan.findings
          .where((final f) => f.componentId == 'ghost')
          .map((final f) => f.code),
      ['orphan'],
    );
    expect(api.stops, isEmpty);
    expect(registry.read(scope, 'ghost'), isNotNull);
  });

  test('invalid desired state fails before any side effect', () async {
    final api = ScriptedProvider();
    const desired = DesiredState(
      specs: [
        ComponentSpec(id: 'api', providerName: 'sh'),
        ComponentSpec(id: 'api', providerName: 'sh'),
      ],
    );
    final report = await makeSupervisor().converge(
      desired: desired,
      factory: (final name) => api,
      evidence: sink,
    );
    expect(report.invalid, isTrue);
    expect(api.starts, isEmpty);
    expect(registry.snapshot(makeSupervisor().scope).records, isEmpty);
  });

  test('failing starts retry within budget and then give up', () async {
    final job = ScriptedProvider()..startError = StateError('boom');
    final supervisor = makeSupervisor();
    final scope = supervisor.scope;
    const desired = DesiredState(
      specs: [
        ComponentSpec(
          id: 'nap',
          providerName: 'chat',
          policy: SupervisionPolicy(
            shape: SupervisionShape.job,
            maxRestarts: 1,
          ),
        ),
      ],
    );
    ResourceProvider factory(final String name) => job;

    final first = await supervisor.converge(
      desired: desired,
      factory: factory,
      evidence: sink,
    );
    expect(first.failedStarts, 1);
    final record = registry.read(scope, 'nap')!;
    expect(record.lastRun, 'failed');
    expect(record.pid, isNull);
    expect(record.restartCount, 0);

    final second = await supervisor.converge(
      desired: desired,
      factory: factory,
      evidence: sink,
    );
    expect(second.failedStarts, 1);
    expect(registry.read(scope, 'nap')!.restartCount, 1);

    final third = await supervisor.converge(
      desired: desired,
      factory: factory,
      evidence: sink,
    );
    expect(third.plan.actions, isEmpty);
    expect(third.plan.findings.map((final f) => f.code), contains('giveUp'));
    expect(job.starts, hasLength(2));
  });

  test('interval jobs re-run only when due', () async {
    final nap = ScriptedProvider();
    final supervisor = makeSupervisor();
    final scope = supervisor.scope;
    const desired = DesiredState(
      specs: [
        ComponentSpec(
          id: 'nap',
          providerName: 'chat',
          policy: SupervisionPolicy(shape: SupervisionShape.job),
          trigger: IntervalTrigger(period: Duration(hours: 6)),
        ),
      ],
    );

    await supervisor.converge(
      desired: desired,
      factory: (final name) => nap,
      evidence: sink,
    );
    var record = registry.read(scope, 'nap')!;
    expect(record.lastRun, 'succeeded');

    // Not due: converged.
    final second = await supervisor.converge(
      desired: desired,
      factory: (final name) => nap,
      evidence: sink,
    );
    expect(second.plan.actions, isEmpty);
    expect(second.plan.findings.single.code, 'succeeded');

    // Due: re-runs.
    now = base.add(const Duration(hours: 7));
    final third = await supervisor.converge(
      desired: desired,
      factory: (final name) => nap,
      evidence: sink,
    );
    expect(third.restarted, 1);
    record = registry.read(scope, 'nap')!;
    expect(record.epoch, 2);
  });

  test(
    'rest-for-one: dependency restart cascades to owned dependents',
    () async {
      final db = ScriptedProvider(outputs: {'db.port': 5101});
      final api = ScriptedProvider();
      final supervisor = makeSupervisor();
      final scope = supervisor.scope;
      const desired = DesiredState(
        specs: [
          ComponentSpec(id: 'db', providerName: 'pg', provides: ['db.port']),
          ComponentSpec(
            id: 'api',
            providerName: 'sh',
            dependsOn: ['db'],
            requires: ['db.port'],
          ),
        ],
      );
      ResourceProvider factory(final String name) => name == 'pg' ? db : api;

      final first = await supervisor.converge(
        desired: desired,
        factory: factory,
        evidence: sink,
      );
      expect(first.started, 2);
      expect(registry.read(scope, 'db')!.outputs['db.port'], 5101);

      db.observation = const Observation(
        state: ResourceState.crashed,
        cause: TerminalCause.exited,
      );
      api.observation = const Observation(state: ResourceState.ready);
      final second = await supervisor.converge(
        desired: desired,
        factory: factory,
        evidence: sink,
      );
      expect(second.restarted, 2);
      expect(second.plan.actions.map((final a) => a.componentId).toList(), [
        'db',
        'api',
      ]);
      // api was stopped (its consumed outputs are stale) and restarted with
      // db's fresh output injected.
      expect(api.stops, hasLength(1));
      final request = api.starts.last;
      expect(
        request.dependencies.require(const OutputRef<int>('db.port')),
        5101,
      );
    },
  );

  test('corrupt registry records surface as findings, never crash', () async {
    final api = ScriptedProvider();
    final supervisor = makeSupervisor();
    final scope = supervisor.scope;
    File('${registry.root}/records/$scope/broken.json')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"componentId":');
    final report = await supervisor.converge(
      desired: const DesiredState(
        specs: [ComponentSpec(id: 'api', providerName: 'sh')],
      ),
      factory: (final name) => api,
      evidence: sink,
    );
    expect(report.started, 1);
    expect(
      report.plan.findings.map((final f) => f.code),
      contains('corruptRecord'),
    );
  });
}
