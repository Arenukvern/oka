import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:resource_composition/resource_composition.dart';
import 'package:test/test.dart';

final DateTime now = DateTime.utc(2026, 10, 9, 12);

SupervisorRecord serviceRecord({
  final String id = 'api',
  final String revisionHash = 'r1',
  final int epoch = 1,
  final int? pid = 100,
  final KillPolicy killPolicy = KillPolicy.spawned,
  final int restartCount = 0,
  final DateTime? windowStartedAt,
  final String? lastRun,
  final DateTime? startedAt,
}) => SupervisorRecord(
  componentId: id,
  providerName: 'leased',
  shape: 'service',
  revisionHash: revisionHash,
  epoch: epoch,
  killPolicy: killPolicy,
  startedAt: startedAt ?? now.subtract(const Duration(hours: 1)),
  restartCount: restartCount,
  windowStartedAt: windowStartedAt ?? now,
  trigger: 'none',
  pid: pid,
  lastRun: lastRun,
);

void main() {
  group('service shape', () {
    test('no record starts', () {
      const desired = DesiredState(
        specs: [ComponentSpec(id: 'api', providerName: 'leased')],
      );
      final plan = planConvergence(
        desired: desired,
        snapshot: const RegistrySnapshot(records: []),
        observations: const {},
        now: now,
      );
      expect(plan.actions, hasLength(1));
      expect(plan.actions.single.kind, SupervisorActionKind.start);
      expect(plan.findings, isEmpty);
    });

    test('ready and matching revision converges with a ready finding', () {
      const spec = ComponentSpec(id: 'api', providerName: 'leased');
      final record = serviceRecord(revisionHash: spec.revisionHash);
      final plan = planConvergence(
        desired: const DesiredState(specs: [spec]),
        snapshot: RegistrySnapshot(records: [record]),
        observations: const {'api': Observation(state: ResourceState.ready)},
        now: now,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.findings.map((final f) => f.code), ['ready']);
    });

    test('unowned but ready reports unowned, never acts', () {
      const spec = ComponentSpec(id: 'api', providerName: 'leased');
      final record = serviceRecord(
        revisionHash: spec.revisionHash,
        killPolicy: KillPolicy.none,
      );
      final plan = planConvergence(
        desired: const DesiredState(specs: [spec]),
        snapshot: RegistrySnapshot(records: [record]),
        observations: const {'api': Observation(state: ResourceState.ready)},
        now: now,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.findings.map((final f) => f.code), contains('unowned'));
    });

    test('dead owned record within budget restarts', () {
      const spec = ComponentSpec(id: 'api', providerName: 'leased');
      final record = serviceRecord(revisionHash: spec.revisionHash);
      final plan = planConvergence(
        desired: const DesiredState(specs: [spec]),
        snapshot: RegistrySnapshot(records: [record]),
        observations: const {
          'api': Observation(
            state: ResourceState.crashed,
            cause: TerminalCause.exited,
          ),
        },
        now: now,
      );
      expect(plan.actions.single.kind, SupervisorActionKind.restart);
      expect(plan.actions.single.reason, contains('crashed'));
    });

    test('dead foreign record is unowned and never signaled', () {
      const spec = ComponentSpec(id: 'api', providerName: 'leased');
      final record = serviceRecord(
        revisionHash: spec.revisionHash,
        killPolicy: KillPolicy.none,
      );
      final plan = planConvergence(
        desired: const DesiredState(specs: [spec]),
        snapshot: RegistrySnapshot(records: [record]),
        observations: const {'api': Observation(state: ResourceState.stopped)},
        now: now,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.findings.single.code, 'unowned');
    });

    test('exhausted budget gives up; revision bump resets', () {
      const spec = ComponentSpec(id: 'api', providerName: 'leased');
      final exhausted = serviceRecord(
        revisionHash: spec.revisionHash,
        restartCount: 3,
      );
      final gaveUp = planConvergence(
        desired: const DesiredState(specs: [spec]),
        snapshot: RegistrySnapshot(records: [exhausted]),
        observations: const {'api': Observation(state: ResourceState.crashed)},
        now: now,
      );
      expect(gaveUp.actions, isEmpty);
      expect(gaveUp.findings.single.code, 'giveUp');

      // An aged-out window restores the budget.
      final aged = serviceRecord(
        revisionHash: spec.revisionHash,
        restartCount: 3,
        windowStartedAt: now.subtract(const Duration(hours: 1)),
      );
      final recovered = planConvergence(
        desired: const DesiredState(specs: [spec]),
        snapshot: RegistrySnapshot(records: [aged]),
        observations: const {'api': Observation(state: ResourceState.crashed)},
        now: now,
      );
      expect(recovered.actions.single.kind, SupervisorActionKind.restart);
    });

    test('terminal failed start restarts within budget without probing', () {
      const spec = ComponentSpec(id: 'api', providerName: 'leased');
      final record = serviceRecord(
        revisionHash: spec.revisionHash,
        pid: null,
        lastRun: 'failed',
        restartCount: 1,
      );
      final plan = planConvergence(
        desired: const DesiredState(specs: [spec]),
        snapshot: RegistrySnapshot(records: [record]),
        observations: const {}, // no probe needed — provider guaranteed it
        now: now,
      );
      expect(plan.actions.single.kind, SupervisorActionKind.restart);
    });

    test('unprovable liveness is an unknown finding', () {
      const spec = ComponentSpec(id: 'api', providerName: 'leased');
      final record = serviceRecord(revisionHash: spec.revisionHash);
      final plan = planConvergence(
        desired: const DesiredState(specs: [spec]),
        snapshot: RegistrySnapshot(records: [record]),
        observations: const {'api': Observation(state: ResourceState.unknown)},
        now: now,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.findings.single.code, 'unknown');
    });
  });

  group('job shape', () {
    const job = ComponentSpec(
      id: 'nap',
      providerName: 'chat',
      policy: SupervisionPolicy(shape: SupervisionShape.job),
    );

    test('no record starts the job', () {
      final plan = planConvergence(
        desired: const DesiredState(specs: [job]),
        snapshot: const RegistrySnapshot(records: []),
        observations: const {},
        now: now,
      );
      expect(plan.actions.single.kind, SupervisorActionKind.start);
    });

    test('running job waits', () {
      final record = serviceRecord(id: 'nap', revisionHash: job.revisionHash);
      final plan = planConvergence(
        desired: const DesiredState(specs: [job]),
        snapshot: RegistrySnapshot(records: [record]),
        observations: const {'nap': Observation(state: ResourceState.starting)},
        now: now,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.findings.single.code, 'waiting');
    });

    test('succeeded once stays done without a trigger', () {
      final record = serviceRecord(
        id: 'nap',
        revisionHash: job.revisionHash,
        pid: null,
        lastRun: 'succeeded',
      );
      final plan = planConvergence(
        desired: const DesiredState(specs: [job]),
        snapshot: RegistrySnapshot(records: [record]),
        observations: const {},
        now: now,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.findings.single.code, 'succeeded');
    });

    test('interval job re-runs only when due', () {
      const dueSpec = ComponentSpec(
        id: 'nap',
        providerName: 'chat',
        policy: SupervisionPolicy(shape: SupervisionShape.job),
        trigger: IntervalTrigger(period: Duration(hours: 6)),
      );
      SupervisorRecord runAt(final DateTime startedAt) => serviceRecord(
        id: 'nap',
        revisionHash: dueSpec.revisionHash,
        pid: null,
        lastRun: 'succeeded',
        startedAt: startedAt,
      );
      final due = planConvergence(
        desired: const DesiredState(specs: [dueSpec]),
        snapshot: RegistrySnapshot(
          records: [runAt(now.subtract(const Duration(hours: 7)))],
        ),
        observations: const {},
        now: now,
      );
      expect(due.actions.single.kind, SupervisorActionKind.restart);

      final notDue = planConvergence(
        desired: const DesiredState(specs: [dueSpec]),
        snapshot: RegistrySnapshot(
          records: [runAt(now.subtract(const Duration(hours: 1)))],
        ),
        observations: const {},
        now: now,
      );
      expect(notDue.isEmpty, isTrue);
      expect(notDue.findings.single.code, 'succeeded');
    });

    test('failed job retries within budget then gives up', () {
      final failed = serviceRecord(
        id: 'nap',
        revisionHash: job.revisionHash,
        pid: null,
        lastRun: 'failed',
      );
      final retry = planConvergence(
        desired: const DesiredState(specs: [job]),
        snapshot: RegistrySnapshot(records: [failed]),
        observations: const {},
        now: now,
      );
      expect(retry.actions.single.kind, SupervisorActionKind.restart);

      final exhausted = serviceRecord(
        id: 'nap',
        revisionHash: job.revisionHash,
        pid: null,
        lastRun: 'failed',
        restartCount: 3,
      );
      final gaveUp = planConvergence(
        desired: const DesiredState(specs: [job]),
        snapshot: RegistrySnapshot(records: [exhausted]),
        observations: const {},
        now: now,
      );
      expect(gaveUp.isEmpty, isTrue);
      expect(gaveUp.findings.single.code, 'giveUp');
    });
  });

  group('cross-cutting laws', () {
    test('orphan records are findings, never targets', () {
      const desired = DesiredState(
        specs: [ComponentSpec(id: 'api', providerName: 'leased')],
      );
      final ghost = serviceRecord(id: 'ghost');
      final plan = planConvergence(
        desired: desired,
        snapshot: RegistrySnapshot(records: [ghost]),
        observations: const {},
        now: now,
      );
      expect(
        plan.actions.where((final a) => a.componentId == 'ghost'),
        isEmpty,
      );
      expect(
        plan.findings
            .where((final f) => f.componentId == 'ghost')
            .map((final f) => f.code),
        ['orphan'],
      );
    });

    test('rest-for-one: restarting a service cascades to owned dependents', () {
      const spec = ComponentSpec(id: 'api', providerName: 'leased');
      final record = serviceRecord(revisionHash: spec.revisionHash);
      final plan = planConvergence(
        desired: const DesiredState(specs: [spec]),
        snapshot: RegistrySnapshot(records: [record]),
        observations: const {'api': Observation(state: ResourceState.crashed)},
        now: now,
      );
      expect(plan.actions.map((final a) => a.componentId), ['api']);
    });

    test('actions are ordered dependencies-first', () {
      const dbSpec = ComponentSpec(id: 'db', providerName: 'leased');
      const apiSpec = ComponentSpec(
        id: 'api',
        providerName: 'leased',
        dependsOn: ['db'],
      );
      final plan = planConvergence(
        desired: const DesiredState(specs: [apiSpec, dbSpec]),
        snapshot: const RegistrySnapshot(records: []),
        observations: const {},
        now: now,
      );
      expect(plan.actions.map((final a) => a.componentId).toList(), [
        'db',
        'api',
      ]);
    });
  });
}
