/// The provider seam: how a component starts, becomes ready, stops, and
/// reconciles (ADR-0026 decision 5).
///
/// Providers own probe mechanics, launch, and stop ladders; the composition
/// contract owns only what is declared. Capabilities are declared so
/// validate-time can reject a provider that cannot meet a component's
/// requirements.
library;

import 'dart:async';

import 'component.dart';
import 'events.dart';
import 'lifecycle.dart';
import 'log_tap.dart';
import 'outputs.dart';
import 'readiness.dart';

/// What a provider can do, declared for composition-time validation.
final class ProviderCapabilities {
  const ProviderCapabilities({
    this.attach = false,
    this.durableIdentity = false,
    this.readinessProbe = false,
  });

  /// The provider can attach to an already-running resource instead of
  /// starting one (`driverForLiveSession`-style, ownership-free).
  final bool attach;

  /// The provider writes the durable pre-side-effect handle and can adopt
  /// resources that outlive their creator (required for
  /// [IdentityRequirement.durable]).
  final bool durableIdentity;

  /// The provider can resolve the declared [Readiness] dialects.
  final bool readinessProbe;
}

/// How a component may be started.
enum StartMode { start, attach }

/// Opaque identity of a running resource.
final class ResourceRef {
  const ResourceRef({
    required this.componentId,
    required this.handle,
    this.pid,
    this.identityToken,
  });

  final String componentId;

  /// Provider-opaque identity (argv, socket path, session id…).
  final String handle;

  /// OS pid when the resource is a process; null otherwise.
  final int? pid;

  /// Start-time identity token captured at spawn, when the provider can
  /// capture one (identity-before-signal, ADR-0018).
  final String? identityToken;
}

/// Cancellation handed to [ResourceProvider.start]: the runner signals it
/// when the readiness budget fires. Providers must honor it — the runner
/// never abandons a start (no `Future.timeout` over live children); it
/// stops and waits.
final class Cancellation {
  final _cancelled = Completer<void>();

  /// Completes when the start should stop trying and return.
  Future<void> get future => _cancelled.future;

  /// Whether cancellation already fired.
  bool get isCancelled => _cancelled.isCompleted;

  /// Runner-side: fires cancellation once.
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// Everything a provider needs to bring one component up.
final class StartRequest {
  const StartRequest({
    required this.component,
    required this.mode,
    required this.dependencies,
    required this.readinessBudget,
    required this.cancellation,
    this.log,
  });

  final Component component;
  final StartMode mode;

  /// Outputs resolved from the component's `dependsOn`, scoped to exactly
  /// the component's declared `requires`.
  final ResolvedOutputs dependencies;

  /// Effective budget: the readiness condition's override, else the
  /// composition default. Providers enforce it via [Cancellation] plus
  /// their own probes — never by abandoning a live child.
  final Duration readinessBudget;

  final Cancellation cancellation;

  /// Bounded capture sink when [Diagnostics.captureOutput] is set.
  final LogTap? log;
}

/// Raised when a provider's start was cancelled before readiness.
final class StartCancelled implements Exception {
  const StartCancelled(this.componentId);

  final String componentId;

  @override
  String toString() => 'Start of "$componentId" was cancelled before ready';
}

/// What a successful start reports.
final class StartReport {
  const StartReport({
    required this.ref,
    this.outputs = ResolvedOutputs.empty,
    this.attached = false,
  });

  final ResourceRef ref;

  /// Resolved values for the component's declared `provides` (validated by
  /// the runner: every declared ref must be present).
  final ResolvedOutputs outputs;
  /// True when the provider attached rather than started.
  final bool attached;
}

/// Lifecycle states an inspection can observe.
enum ResourceState { starting, ready, stopped, crashed, unknown }

/// Result of inspecting or reconciling a resource.
final class Observation {
  const Observation({
    required this.state,
    this.cause,
    this.message,
  });

  final ResourceState state;

  /// Terminal cause when [state] is [ResourceState.stopped] or
  /// [ResourceState.crashed]; [TerminalCause.unknown] when unprovable.
  final TerminalCause? cause;
  final String? message;
}

/// How a stop ended.
enum StopDisposition {
  /// Verified stopped (exit awaited).
  stopped,

  /// Was already stopped when the stop ran.
  alreadyStopped,

  /// Identity or liveness unprovable; nothing signaled — report only.
  unknown,

  /// The provider refused (e.g. a borrowed resource without force).
  refused,
}

/// Result of a stop. Providers verify death before reporting
/// [StopDisposition.stopped]; fire-and-forget kills are the anti-pattern
/// the R0 survey found everywhere.
final class StopReport {
  const StopReport({
    required this.disposition,
    this.cause,
    this.message,
  });

  final StopDisposition disposition;
  final TerminalCause? cause;
  final String? message;

  bool get stopped =>
      disposition == StopDisposition.stopped ||
      disposition == StopDisposition.alreadyStopped;
}

/// The seam every resource kind implements — process-backed services,
/// protocol sessions, external resources — without sharing a superclass
/// with `kind` switches (ADR-0026 decision 1).
abstract interface class ResourceProvider {
  /// Declared for composition-time validation.
  ProviderCapabilities get capabilities;

  /// Brings the component up (or attaches) and returns once it is READY —
  /// readiness is resolved here, per the component's declared condition.
  ///
  /// Contract:
  /// - honor [StartRequest.cancellation]: after it fires, complete promptly
  ///   by throwing [StartCancelled] (or returning a report); the runner
  ///   never abandons a start.
  /// - resolve every output the component declares in `provides`, or fail.
  /// - a failed start leaves nothing running: stop what this start spawned
  ///   before throwing.
  Future<StartReport> start(final StartRequest request);

  /// Read-only observation; never mutates or signals.
  Future<Observation> inspect(final ResourceRef ref);

  /// Stops with the graceful→force ladder, awaits the exit, and verifies
  /// death before reporting [StopDisposition.stopped]. Borrowed/foreign
  /// resources are refused, not guessed.
  Future<StopReport> stop(
    final ResourceRef ref, {
    required final Duration grace,
  });

  /// Crash/late reconciliation: report what is observable. `unknown` when
  /// identity cannot be proven — evidence, never authority to terminate.
  Future<Observation> reconcile(final ResourceRef ref);
}
