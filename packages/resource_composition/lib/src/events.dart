/// Structured lifecycle events with terminal causes (ADR-0026 decision 5).
///
/// Evidence records the *meaning* of death, not just the fact — the R0
/// survey (failure class F5) found systems where a deadline kill, a
/// provider fault, and a transport loss were indistinguishable at the
/// process boundary. Events are the day-one evidence surface; retention
/// and redaction are sink policies, deferred until a second consumer
/// demands them.
library;

import 'dart:convert';

/// Why a component's run ended.
enum TerminalCause {
  /// Exited by itself before any deadline.
  exited,

  /// Killed by a signal it did not handle.
  signaled,

  /// The declared readiness budget (or a stop deadline) fired and the
  /// owned tree was stopped. Never "abandoned".
  killedOnDeadline,

  /// The provider or its backend failed (quota, auth, crash of the serving
  /// process) while the resource itself was healthy.
  providerFault,

  /// The transport to a still-healthy resource was lost (stdio closed,
  /// socket dropped); the resource's true state is an observation-shaped
  /// unknown until probed.
  transportLost,

  /// Identity or liveness could not be established. Never silently
  /// upgraded to alive or dead — report-never-guess (ADR-0018).
  unknown,
}

/// Kinds of lifecycle events; stable strings for the JSONL line.
enum LifecycleEventKind {
  componentStarting('componentStarting'),
  componentReady('componentReady'),
  readinessTimeout('readinessTimeout'),
  componentFailed('componentFailed'),
  componentStopped('componentStopped'),
  reconcileObserved('reconcileObserved'),
  supervisorFinding('supervisorFinding');

  const LifecycleEventKind(this.wire);

  /// Stable wire name used in JSONL evidence.
  final String wire;
}

/// Base class of structured lifecycle events.
sealed class LifecycleEvent {
  LifecycleEvent({required this.componentId, final DateTime? at})
    : at = at ?? DateTime.now().toUtc();

  final String componentId;

  /// When the event happened (UTC); injectable for deterministic tests.
  final DateTime at;

  LifecycleEventKind get kind;

  /// Structured detail for this event; values must be JSON-encodable.
  Map<String, Object?> get details => const {};

  /// One JSONL line: stable field order `kind, component, at, …details`.
  String toJsonLine() {
    final line = <String, Object?>{
      'kind': kind.wire,
      'component': componentId,
      'at': at.toIso8601String(),
      ...details,
    };
    return jsonEncode(line);
  }
}

/// A component's start was handed to its provider.
final class ComponentStarting extends LifecycleEvent {
  ComponentStarting({
    required super.componentId,
    super.at,
    this.attached = false,
  });

  /// True when the provider attached to an existing resource instead of
  /// starting one (an `attach` capability).
  final bool attached;

  @override
  LifecycleEventKind get kind => LifecycleEventKind.componentStarting;

  @override
  Map<String, Object?> get details => {'attached': attached};
}

/// A component became ready; its declared outputs are resolved.
final class ComponentReady extends LifecycleEvent {
  ComponentReady({
    required super.componentId,
    super.at,
    this.outputs = const <String, Object?>{},
  });

  /// Resolved output values keyed by [OutputRef.id] (already validated
  /// against the component's declared provides).
  final Map<String, Object?> outputs;

  @override
  LifecycleEventKind get kind => LifecycleEventKind.componentReady;

  @override
  Map<String, Object?> get details => {'outputs': outputs};
}

/// The readiness budget fired; the owned tree was stopped, never abandoned.
final class ReadinessTimeout extends LifecycleEvent {
  ReadinessTimeout({
    required super.componentId,
    required this.budget, super.at,
  });

  final Duration budget;

  @override
  LifecycleEventKind get kind => LifecycleEventKind.readinessTimeout;

  @override
  Map<String, Object?> get details => {'budgetMs': budget.inMilliseconds};
}

/// A component's start failed for a reason other than readiness.
final class ComponentFailed extends LifecycleEvent {
  ComponentFailed({
    required super.componentId,
    required this.cause, super.at,
    this.message,
  });

  final TerminalCause cause;
  final String? message;

  @override
  LifecycleEventKind get kind => LifecycleEventKind.componentFailed;

  @override
  Map<String, Object?> get details => {
    'cause': cause.name,
    if (message != null) 'message': message,
  };
}

/// A running component was stopped (or observed stopped).
final class ComponentStopped extends LifecycleEvent {
  ComponentStopped({
    required super.componentId,
    required this.cause, super.at,
    this.message,
  });

  final TerminalCause cause;
  final String? message;

  @override
  LifecycleEventKind get kind => LifecycleEventKind.componentStopped;

  @override
  Map<String, Object?> get details => {
    'cause': cause.name,
    if (message != null) 'message': message,
  };
}

/// A later invocation reconciled an outlived resource; the observation is
/// report-only.
final class ReconcileObserved extends LifecycleEvent {
  ReconcileObserved({
    required super.componentId,
    required this.observation, super.at,
  });

  /// `unknown | stopped | crashed | ready` — never an auto-decision.
  final String observation;

  @override
  LifecycleEventKind get kind => LifecycleEventKind.reconcileObserved;

  @override
  Map<String, Object?> get details => {'observation': observation};
}

/// A steady-state supervisor finding (ADR-0040): the convergence diff
/// reported something that is not an action — a healthy component, a
/// waiting job, an orphan record, an unowned process, or an exhausted
/// restart budget. Findings are evidence; only budgeted, owned actions
/// change the world.
final class SupervisorFindingEvent extends LifecycleEvent {
  SupervisorFindingEvent({
    required super.componentId,
    required this.code,
    this.message,
    super.at,
  });

  /// Stable finding code, e.g. `giveUp`, `orphan`, `unowned`, `ready`.
  final String code;

  final String? message;

  @override
  LifecycleEventKind get kind => LifecycleEventKind.supervisorFinding;

  @override
  Map<String, Object?> get details => {
        'code': code,
        if (message != null) 'message': message,
      };
}
