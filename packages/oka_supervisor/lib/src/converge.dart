/// The convergence driver (ADR-0040 decision 2): validate → observe →
/// plan → apply once → exit. Crash-only by construction — there is no
/// resident loop in rung 1; run `converge` again whenever state should
/// re-converge (a watcher, cron line, or the resident rung may call it).
///
/// Apply discipline per component mirrors the substrate runner's
/// guarantees for a single node: budgeted cancellation (never abandons a
/// live child), declared-output verification, events at every transition,
/// and a pre-spawn registry record (identity-before-side-effects).
library;

import 'dart:async';

import 'package:resource_composition/resource_composition.dart';

import 'planner.dart';
import 'registry.dart';
import 'spec.dart';

/// What one converge pass did.
final class ConvergenceReport {
  const ConvergenceReport({
    required this.plan,
    this.started = 0,
    this.restarted = 0,
    this.failedStarts = 0,
    this.invalid = false,
  });

  final SupervisorPlan plan;
  final int started;
  final int restarted;
  final int failedStarts;

  /// True when the desired state itself failed validation — nothing was
  /// observed or applied.
  final bool invalid;

  bool get ok => !invalid && failedStarts == 0;

  String describe() {
    final buffer = StringBuffer()
      ..writeln(
        'converge${invalid ? ' INVALID' : ''}: ${plan.startCount} to start, '
        '${plan.restartCount} to restart, ${plan.findings.length} finding(s)',
      )
      ..write(plan.describe());
    return buffer.toString();
  }
}

/// Steady-state supervisor bound to one project scope.
final class Supervisor {
  Supervisor({
    required this.projectRoot,
    final MachineRegistry? registry,
    final DateTime Function()? clock,
  })  : registry = registry ?? MachineRegistry.forMachine(),
        clock = clock ?? (() => DateTime.now().toUtc());

  /// The project whose desired state this supervisor converges; the
  /// registry scope derives from its canonical path.
  final String projectRoot;
  final MachineRegistry registry;

  /// Injectable for deterministic tests (budget windows, interval dues).
  final DateTime Function() clock;

  String get scope => registry.scopeFor(projectRoot);

  /// One convergence pass. With [apply] false this is a pure dry run:
  /// read-only observation, plan returned, nothing mutated anywhere.
  Future<ConvergenceReport> converge({
    required final DesiredState desired,
    required final ProviderFactory factory,
    final EvidenceSink? evidence,
    final bool apply = true,
  }) async {
    final now = clock();
    final sink = evidence ?? _NullSink();

    // 1. Validate — zero side effects; providers never contacted.
    final Composition composition;
    try {
      composition = desired.composition(factory);
      // An unresolved provider name is a declaration bug, surfaced as a
      // finding, never a crash.
      // ignore: avoid_catching_errors
    } on ArgumentError catch (error) {
      return ConvergenceReport(
        plan: SupervisorPlan(actions: [], findings: [
          SupervisorFinding(
            code: 'invalidSpec',
            componentId: '*',
            message: '$error',
          ),
        ]),
        invalid: true,
      );
    }
    final validation = composition.validate();
    if (!validation.ok) {
      return ConvergenceReport(
        plan: SupervisorPlan(actions: [], findings: [
          for (final issue in validation.issues)
            SupervisorFinding(
              code: 'invalidSpec',
              componentId: issue.componentId ?? '*',
              message: '${issue.code}: ${issue.message}',
            ),
        ]),
        invalid: true,
      );
    }

    // 2. Observe — read-only inspection of recorded refs.
    final snapshot = registry.snapshot(scope);
    final specs = desired.byId();
    final components = {
      for (final component in composition.components) component.id: component,
    };
    final observations = <String, Observation>{};
    for (final record in snapshot.records) {
      final spec = specs[record.componentId];
      if (spec == null) continue; // orphan — planner reports it
      if (record.pid == null &&
          record.killPolicy == KillPolicy.spawned &&
          record.lastRun != null) {
        continue; // terminal record from our own start; planner trusts it
      }
      final provider = factory(spec.providerName);
      final ref = ResourceRef(
        componentId: record.componentId,
        handle: record.handle ?? '',
        pid: record.pid,
        identityToken: record.identityToken,
      );
      try {
        observations[record.componentId] = await provider.inspect(ref);
      } on Object catch (error) {
        observations[record.componentId] = Observation(
          state: ResourceState.unknown,
          cause: TerminalCause.unknown,
          message: 'inspect threw: $error',
        );
      }
    }

    // 3. Plan.
    final plan = planConvergence(
      desired: desired,
      snapshot: snapshot,
      observations: observations,
      now: now,
    );

    var started = 0;
    var restarted = 0;
    var failedStarts = 0;

    // 4. Apply — actions only, in plan (dependency) order.
    if (apply) {
      for (final action in plan.actions) {
        final spec = specs[action.componentId]!;
        final component = components[action.componentId]!;
        final provider = factory(spec.providerName);
        final previous = snapshot[action.componentId];

        var restartCount = 0;
        var windowStartedAt = now;
        if (action.kind == SupervisorActionKind.restart &&
            previous != null) {
          // The revision bump IS the budget reset.
          final base =
              previous.revisionHash != spec.revisionHash ||
                      now.difference(previous.windowStartedAt) >
                          spec.policy.restartWindow
                  ? 0
                  : previous.restartCount;
          restartCount = base + 1; // this restart consumes the budget now
          windowStartedAt =
              base == 0 ? now : previous.windowStartedAt;
        }

        if (action.kind == SupervisorActionKind.restart &&
            previous != null &&
            previous.pid != null) {
          final ref = ResourceRef(
            componentId: previous.componentId,
            handle: previous.handle ?? '',
            pid: previous.pid,
            identityToken: previous.identityToken,
          );
          final stopReport = await provider.stop(
            ref,
            grace: component.lifecycle.stop.grace,
          );
          sink.add(ComponentStopped(
            componentId: spec.id,
            cause: stopReport.cause ?? TerminalCause.exited,
            message: stopReport.message,
          ));
          if (!stopReport.stopped) {
            plan.findings.add(SupervisorFinding(
              code: 'unknown',
              componentId: spec.id,
              message:
                  'restart aborted: stop reported '
                  '${stopReport.disposition.name} — report-never-guess',
            ));
            continue;
          }
        }

        final outcome = await _start(
          spec: spec,
          component: component,
          provider: provider,
          evidence: sink,
          now: now,
          epoch: (previous?.epoch ?? 0) + 1,
          restartCount: restartCount,
          windowStartedAt: windowStartedAt,
          snapshot: snapshot,
          defaultBudget: desired.readinessBudget,
        );
        if (outcome.failed) {
          failedStarts++;
        } else if (action.kind == SupervisorActionKind.restart) {
          restarted++;
        } else {
          started++;
        }
      }
    }

    // 5. Emit findings.
    for (final finding in plan.findings) {
      sink.add(SupervisorFindingEvent(
        componentId: finding.componentId,
        code: finding.code,
        message: finding.message,
      ));
    }

    return ConvergenceReport(
      plan: plan,
      started: started,
      restarted: restarted,
      failedStarts: failedStarts,
    );
  }

  Future<_StartOutcome> _start({
    required final ComponentSpec spec,
    required final Component component,
    required final ResourceProvider provider,
    required final EvidenceSink evidence,
    required final DateTime now,
    required final int epoch,
    required final int restartCount,
    required final DateTime windowStartedAt,
    required final RegistrySnapshot snapshot,
    required final Duration defaultBudget,
  }) async {
    final isJob = spec.policy.shape == SupervisionShape.job;

    // Pre-spawn record: identity-before-side-effects. If we crash after
    // this line, the record names what exists — never an invisible orphan.
    var record = SupervisorRecord(
      componentId: spec.id,
      providerName: spec.providerName,
      shape: spec.policy.shape.name,
      revisionHash: spec.revisionHash,
      epoch: epoch,
      killPolicy: KillPolicy.spawned,
      startedAt: now,
      restartCount: restartCount,
      windowStartedAt: windowStartedAt,
      trigger: spec.trigger.describe(),
    );
    registry.upsert(record, scope: scope);

    evidence.add(ComponentStarting(componentId: spec.id));

    final dependencies = _resolvedDependencies(spec, snapshot);
    final budget = spec.readiness?.budget ?? defaultBudget;
    final cancellation = Cancellation();
    final log = LogTap(name: spec.id);

    final StartReport startReport;
    try {
      final startFuture = provider.start(
        StartRequest(
          component: component,
          mode: StartMode.start,
          dependencies: dependencies,
          readinessBudget: budget,
          cancellation: cancellation,
          log: log,
        ),
      );
      final timer = Timer(budget, cancellation.cancel);
      try {
        startReport = await startFuture;
      } finally {
        timer.cancel();
      }
    } on StartCancelled {
      evidence.add(ReadinessTimeout(componentId: spec.id, budget: budget));
      record = record.copyWith(
        clearProcess: true,
        lastRun: 'failed',
      );
      registry.upsert(record, scope: scope);
      return const _StartOutcome.failed();
    } on Object catch (error) {
      evidence.add(ComponentFailed(
        componentId: spec.id,
        cause: TerminalCause.providerFault,
        message: '$error',
      ));
      record = record.copyWith(clearProcess: true, lastRun: 'failed');
      registry.upsert(record, scope: scope);
      return const _StartOutcome.failed();
    }

    final unresolved = component.provides
        .where((final ref) => !startReport.outputs.contains(ref))
        .toList();
    if (unresolved.isNotEmpty) {
      await provider.stop(
        startReport.ref,
        grace: component.lifecycle.stop.grace,
      );
      evidence.add(ComponentFailed(
        componentId: spec.id,
        cause: TerminalCause.providerFault,
        message: 'did not resolve declared outputs: '
            '${unresolved.map((final r) => r.id).join(', ')}',
      ));
      record = record.copyWith(clearProcess: true, lastRun: 'failed');
      registry.upsert(record, scope: scope);
      return const _StartOutcome.failed();
    }

    record = record.copyWith(
      pid: startReport.ref.pid,
      handle: startReport.ref.handle,
      identityToken: startReport.ref.identityToken,
      outputs: _outputsById(component, startReport.outputs),
      // Jobs: the run-to-exit provider contract means a returned start IS
      // a completed run — the process is gone, so the record is terminal
      // and the next converge judges it without probing.
      lastRun: isJob ? 'succeeded' : null,
      clearProcess: isJob,
    );
    registry.upsert(record, scope: scope);
    evidence.add(ComponentReady(
      componentId: spec.id,
      outputs: {
        for (final ref in component.provides)
          ref.id: startReport.outputs.require(ref),
      },
    ));
    return const _StartOutcome.started();
  }

  ResolvedOutputs _resolvedDependencies(
    final ComponentSpec spec,
    final RegistrySnapshot snapshot,
  ) {
    final values = <String, Object?>{};
    for (final refId in spec.requires) {
      for (final depId in spec.dependsOn) {
        final depRecord = snapshot[depId];
        final value = depRecord?.outputs[refId];
        if (value != null) values[refId] = value;
      }
    }
    return ResolvedOutputs(values);
  }

  Map<String, Object?> _outputsById(
    final Component component,
    final ResolvedOutputs outputs,
  ) => {
        for (final ref in component.provides)
          if (outputs.contains(ref)) ref.id: outputs.require(ref),
      };
}

final class _StartOutcome {
  const _StartOutcome.started() : failed = false;
  const _StartOutcome.failed() : failed = true;

  final bool failed;
}

final class _NullSink implements EvidenceSink {
  @override
  void add(final LifecycleEvent event) {}
}
