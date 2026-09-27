/// Lifecycle policies: declared, never implicit (ADR-0026 decisions 5–7).
///
/// Scopes mirror ADR-0018: `ephemeral` resources die with the composing
/// run, `session` resources survive rebuilds within their owning session,
/// `persistent` resources outlive it and must be discoverable and stoppable
/// through a durable handle. There is no default restart policy; crash
/// behavior is [CrashPolicy.report] unless a provider explicitly offers
/// reconciliation.
library;

/// How long a resource may live relative to its owner.
enum ResourceScope {
  /// Dies when the composing run ends — normal exit, failure, or signal.
  ephemeral,

  /// Dies when the owning session ends; survives rebuilds within it.
  session,

  /// Outlives the owner; requires durable identity to be adoptable.
  persistent,
}

/// What happens when a running component crashes or its death is observed.
///
/// `reconcile` means *report and let a later invocation decide* — never an
/// implicit restart (the R0 survey found zero demand for restart loops).
enum CrashPolicy {
  /// The death is recorded with its terminal cause; nothing restarts.
  report,

  /// The death is recorded and the component becomes a reconciliation
  /// target for a later invocation; still never an automatic restart.
  reconcile,
}

/// Whether a component needs durable identity to be safe around its own
/// lifecycle.
enum IdentityRequirement {
  /// A live parent handle is enough (command-scoped child processes).
  liveParent,

  /// The component can outlive its creator and must write the durable
  /// pre-side-effect handle (ADR-0026 decision 6) so a later invocation
  /// can adopt or stop it; requires the provider's `durableIdentity`
  /// capability.
  durable,
}

/// Time-bounded stop policy: graceful first, then force, verified death.
final class StopLadder {
  const StopLadder({this.grace = const Duration(seconds: 5)});

  /// How long the graceful rung may take before force is applied.
  final Duration grace;
}

/// The lifecycle declared for a component. Values, not a type hierarchy —
/// the same law as ADR-0017 §5.
final class Lifecycle {
  const Lifecycle({
    this.scope = ResourceScope.ephemeral,
    this.onCrash = CrashPolicy.report,
    this.identity = IdentityRequirement.liveParent,
    this.stop = const StopLadder(),
  });

  final ResourceScope scope;
  final CrashPolicy onCrash;
  final IdentityRequirement identity;
  final StopLadder stop;

  Lifecycle copyWith({
    final ResourceScope? scope,
    final CrashPolicy? onCrash,
    final IdentityRequirement? identity,
    final StopLadder? stop,
  }) =>
      Lifecycle(
        scope: scope ?? this.scope,
        onCrash: onCrash ?? this.onCrash,
        identity: identity ?? this.identity,
        stop: stop ?? this.stop,
      );
}

/// Diagnostic capture policy: evidence is bounded and policy-controlled.
final class Diagnostics {
  const Diagnostics({
    this.captureOutput = true,
    this.captureCrashArtifacts = false,
  });

  /// Whether the provider should route stdout/stderr through a bounded
  /// [LogTap]-shaped sink.
  final bool captureOutput;

  /// Whether crash artifacts (stack traces, core dumps) should be preserved
  /// when available. Retention is a sink policy, never implicit.
  final bool captureCrashArtifacts;
}
