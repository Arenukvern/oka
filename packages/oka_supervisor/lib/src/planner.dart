/// The convergence planner: a pure function from desired state, registry
/// records, and observations to actions and findings (ADR-0040 decision
/// 2). No I/O, no side effects — tests assert on plan values before any
/// apply.
///
/// Laws encoded here:
/// - kill rights: restart/stop are proposed only for records with
///   `killPolicy != none` (spawn lineage or cession);
/// - report-never-guess: unprovable state becomes `unknown` findings;
/// - budgeted restarts: exhausting the ledger yields a terminal `giveUp`;
/// - orphans are findings, never targets;
/// - rest-for-one cascade: restarting a service makes its dependents
///   stale, so they re-converge too.
library;

import 'package:resource_composition/resource_composition.dart';

import 'registry.dart';
import 'spec.dart';

/// What the driver should do to one component.
enum SupervisorActionKind {
  /// Bring up (no live record, or prior record fully consumed).
  start,

  /// Stop (verified) then start again — same as the substrate's
  /// discipline: never fire-and-forget.
  restart,
}

final class SupervisorAction {
  const SupervisorAction({
    required this.kind,
    required this.componentId,
    required this.reason,
  });

  final SupervisorActionKind kind;
  final String componentId;
  final String reason;

  @override
  String toString() => '${kind.name} $componentId ($reason)';
}

/// A steady-state observation that is not an action. Evidence only.
final class SupervisorFinding {
  const SupervisorFinding({
    required this.code,
    required this.componentId,
    required this.message,
  });

  /// `ready | waiting | succeeded | unknown | orphan | unowned |
  /// driftedUnowned | giveUp | corruptRecord | invalidSpec`.
  final String code;
  final String componentId;
  final String message;

  @override
  String toString() => '$code $componentId: $message';
}

/// The diff: actions to apply (in dependency order) and findings to emit.
final class SupervisorPlan {
  const SupervisorPlan({
    required this.actions,
    required this.findings,
  });

  static const empty = SupervisorPlan(actions: [], findings: []);

  final List<SupervisorAction> actions;
  final List<SupervisorFinding> findings;

  bool get isEmpty => actions.isEmpty;

  int get startCount =>
      actions.where((final a) => a.kind == SupervisorActionKind.start).length;

  int get restartCount => actions
      .where((final a) => a.kind == SupervisorActionKind.restart)
      .length;

  /// Deterministic rendering for CLI surfaces and tests.
  String describe() {
    final buffer = StringBuffer();
    if (actions.isEmpty) {
      buffer.writeln('plan: no actions (state converged)');
    } else {
      buffer.writeln('plan:');
      for (final action in actions) {
        buffer.writeln('  - $action');
      }
    }
    for (final finding in findings) {
      buffer.writeln('  ? $finding');
    }
    return buffer.toString().trimRight();
  }
}

/// Computes the convergence plan.
///
/// [observations] are keyed by component id and must come from
/// `provider.inspect` on the *recorded* ref (read-only). Records whose
/// process fields are cleared but which carry a `lastRun` verdict from a
/// start this supervisor performed are judged from the record — the
/// provider guaranteed nothing is running, so no probe is needed.
SupervisorPlan planConvergence({
  required final DesiredState desired,
  required final RegistrySnapshot snapshot,
  required final Map<String, Observation> observations,
  required final DateTime now,
}) {
  final specs = desired.byId();
  final findings = <SupervisorFinding>[];
  for (final path in snapshot.corruptPaths) {
    findings.add(SupervisorFinding(
      code: 'corruptRecord',
      componentId: path.split('/').last,
      message: 'registry record could not be parsed: $path',
    ));
  }
  for (final record in snapshot.records) {
    if (!specs.containsKey(record.componentId)) {
      findings.add(SupervisorFinding(
        code: 'orphan',
        componentId: record.componentId,
        message:
            'recorded but not declared; observe-only, never signaled '
            '(killPolicy ${record.killPolicy.name})',
      ));
    }
  }

  final actions = <SupervisorAction>[];
  for (final spec in specs.values) {
    _planOne(
      spec: spec,
      record: snapshot[spec.id],
      observation: observations[spec.id],
      now: now,
      actions: actions,
      findings: findings,
    );
  }
  _cascadeRestForOne(specs, snapshot, actions, findings);
  _orderTopologically(specs, actions);
  return SupervisorPlan(actions: actions, findings: findings);
}

void _planOne({
  required final ComponentSpec spec,
  required final SupervisorRecord? record,
  required final Observation? observation,
  required final DateTime now,
  required final List<SupervisorAction> actions,
  required final List<SupervisorFinding> findings,
}) {
  final policy = spec.policy;
  final drift = record != null && record.revisionHash != spec.revisionHash;
  final owned = record != null && record.killPolicy != KillPolicy.none;

  if (record == null) {
    actions.add(SupervisorAction(
      kind: SupervisorActionKind.start,
      componentId: spec.id,
      reason: 'declared ${policy.shape.name} with no record',
    ));
    return;
  }

  // A start this supervisor performed and recorded as terminal: the
  // provider guarantees nothing is running, so the record is the truth.
  final recordTerminal = record.pid == null &&
      record.killPolicy == KillPolicy.spawned &&
      record.lastRun != null;

  if (recordTerminal) {
    if (policy.shape == SupervisionShape.job &&
        record.lastRun == 'succeeded' &&
        !drift) {
      final trigger = spec.trigger;
      if (trigger is IntervalTrigger) {
        final due = now.difference(record.startedAt) >= trigger.period;
        if (due) {
          actions.add(SupervisorAction(
            kind: SupervisorActionKind.restart,
            componentId: spec.id,
            reason:
                'interval ${trigger.period.inSeconds}s due (last run '
                '${now.difference(record.startedAt).inMinutes}m ago)',
          ));
        } else {
          findings.add(SupervisorFinding(
            code: 'succeeded',
            componentId: spec.id,
            message:
                'ran ${now.difference(record.startedAt).inMinutes}m ago; '
                'next run within ${trigger.period.inSeconds}s interval',
          ));
        }
        return;
      }
      findings.add(SupervisorFinding(
        code: 'succeeded',
        componentId: spec.id,
        message: 'completed for revision ${spec.revisionHash}',
      ));
      return;
    }
    if (policy.shape == SupervisionShape.job &&
        record.lastRun == 'succeeded' &&
        drift) {
      actions.add(SupervisorAction(
        kind: SupervisorActionKind.restart,
        componentId: spec.id,
        reason: 'declaration changed; re-running job',
      ));
      return;
    }
    // Terminal failed (service or job) or terminal service success.
    if (policy.shape == SupervisionShape.service &&
        record.lastRun == 'succeeded' &&
        !drift) {
      // A service provider that returned while still running records no
      // lastRun; 'succeeded' on a service is a provider contract error —
      // report, never guess.
      findings.add(SupervisorFinding(
        code: 'unknown',
        componentId: spec.id,
        message:
            'service record carries lastRun=succeeded; providers of '
            'services must not report terminal success',
      ));
      return;
    }
    // A revision bump IS the budget reset (ADR-0040 decision 3): a
    // changed declaration restarts regardless of the spent ledger.
    if (drift || _budgetLeft(record, policy, now)) {
      actions.add(SupervisorAction(
        kind: SupervisorActionKind.restart,
        componentId: spec.id,
        reason:
            'prior ${policy.shape.name} ${record.lastRun}; '
            '${drift ? 'declaration changed (budget reset)' : 'within budget'}',
      ));
    } else {
      findings.add(SupervisorFinding(
        code: 'giveUp',
        componentId: spec.id,
        message:
            'restart budget exhausted (${record.restartCount} in window); '
            'bump the policy revision to reset',
      ));
    }
    return;
  }

  final obs = observation;
  if (obs == null) {
    findings.add(SupervisorFinding(
      code: 'unknown',
      componentId: spec.id,
      message: 'record without observation; converge must observe every '
          'non-terminal record',
    ));
    return;
  }

  switch (obs.state) {
    case ResourceState.starting:
      findings.add(SupervisorFinding(
        code: 'waiting',
        componentId: spec.id,
        message: 'still starting',
      ));
    case ResourceState.ready:
      if (drift) {
        if (owned) {
          actions.add(SupervisorAction(
            kind: SupervisorActionKind.restart,
            componentId: spec.id,
            reason: 'declaration changed',
          ));
        } else {
          findings.add(SupervisorFinding(
            code: 'driftedUnowned',
            componentId: spec.id,
            message: 'declaration changed but the process is unowned; '
                'observe-only',
          ));
        }
        return;
      }
      findings.add(SupervisorFinding(
        code: 'ready',
        componentId: spec.id,
        message: 'converged',
      ));
      if (!owned) {
        findings.add(SupervisorFinding(
          code: 'unowned',
          componentId: spec.id,
          message: 'running with killPolicy none; it can be observed but '
              'never stopped by this supervisor',
        ));
      }
    case ResourceState.stopped:
    case ResourceState.crashed:
      if (!owned) {
        findings.add(SupervisorFinding(
          code: 'unowned',
          componentId: spec.id,
          message:
              'observed ${obs.state.name} (${obs.cause?.name ?? 'unknown '
                  'cause'}); foreign record — never signaled',
        ));
        return;
      }
      // A revision bump IS the budget reset: drift restarts even when the
      // ledger is spent.
      if (!drift && !_budgetLeft(record, policy, now)) {
        findings.add(SupervisorFinding(
          code: 'giveUp',
          componentId: spec.id,
          message:
              'restart budget exhausted (${record.restartCount} in window); '
              'bump the policy revision to reset',
        ));
        return;
      }
      actions.add(SupervisorAction(
        kind: SupervisorActionKind.restart,
        componentId: spec.id,
        reason:
            'observed ${obs.state.name} (${obs.cause?.name ?? 'unknown'})'
            '${drift ? '; declaration changed' : ''}',
      ));
    case ResourceState.unknown:
      findings.add(SupervisorFinding(
        code: 'unknown',
        componentId: spec.id,
        message: obs.message ?? 'identity or liveness unprovable; '
            'report-never-guess',
      ));
  }
}

/// rest_for_one, minimally: a restart invalidates the outputs downstream
/// components consumed at start time, so owned dependents re-converge in
/// the same pass (unowned ones get a finding).
void _cascadeRestForOne(
  final Map<String, ComponentSpec> specs,
  final RegistrySnapshot snapshot,
  final List<SupervisorAction> actions,
  final List<SupervisorFinding> findings,
) {
  var changed = true;
  final restarts = {
    for (final action in actions)
      if (action.kind == SupervisorActionKind.restart) action.componentId,
  };
  while (changed) {
    changed = false;
    for (final spec in specs.values) {
      if (restarts.contains(spec.id)) continue;
      final dependsOnRestart = spec.dependsOn.any(restarts.contains);
      if (!dependsOnRestart) continue;
      final record = snapshot[spec.id];
      if (record == null) continue; // starting anyway (or planned above)
      restarts.add(spec.id);
      changed = true;
      if (record.killPolicy == KillPolicy.none) {
        findings.add(SupervisorFinding(
          code: 'driftedUnowned',
          componentId: spec.id,
          message: 'dependency restarting; outputs stale but this process '
              'is unowned — observe-only',
        ));
        continue;
      }
      actions.add(SupervisorAction(
        kind: SupervisorActionKind.restart,
        componentId: spec.id,
        reason: 'dependency restarting; consumed outputs are stale',
      ));
    }
  }
}

/// Actions apply in the desired state's dependency order: stable
/// topological order over the spec graph (ties keep declaration order).
void _orderTopologically(
  final Map<String, ComponentSpec> specs,
  final List<SupervisorAction> actions,
) {
  final position = <String, int>{
    for (final entry in specs.keys.toList().asMap().entries)
      entry.value: entry.key,
  };
  int rank(final String id) {
    // Depth from roots: deps first; simple memoized DFS (graphs are tiny).
    final seen = <String>{};
    int depth(final String current) {
      if (!seen.add(current)) return 0;
      final deps = specs[current]?.dependsOn ?? const <String>[];
      return deps.isEmpty
          ? 0
          : 1 + deps.map(depth).reduce((final a, final b) => a > b ? a : b);
    }

    return depth(id);
  }

  actions.sort((final a, final b) {
    final byDepth = rank(a.componentId).compareTo(rank(b.componentId));
    if (byDepth != 0) return byDepth;
    final byPosition = (position[a.componentId] ?? 0).compareTo(
      position[b.componentId] ?? 0,
    );
    return byPosition;
  });
}

bool _budgetLeft(
  final SupervisorRecord record,
  final SupervisionPolicy policy,
  final DateTime now,
) {
  final windowExpired =
      now.difference(record.windowStartedAt) > policy.restartWindow;
  return windowExpired || record.restartCount < policy.maxRestarts;
}
