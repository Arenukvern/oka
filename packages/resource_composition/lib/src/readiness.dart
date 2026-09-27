/// Readiness as a first-class typed declaration (ADR-0026 decision 4).
///
/// A component declares *that* and *how* it must become ready; the probe
/// *mechanics* stay provider-internal. Budgets are declared so `explain`
/// can show them before anything starts — ending the per-call-site timeout
/// lottery the R0 survey found in every system (1.5 s–180 s per site).
/// An unready component can never satisfy a `dependsOn` edge.
library;

/// How a provider may observe that a component is ready.
sealed class Readiness {
  const Readiness({this.budget});

  /// Overrides the composition's default budget for this condition.
  final Duration? budget;

  /// Deterministic text for `explain` — no side effects.
  String describe();
}

/// One stdout/stderr frame announcing readiness, optionally parsed into
/// typed outputs.
///
/// This is the dialect three systems converged on (the collector
/// monorepo's JSON handshake line, the agent harness's magic strings done
/// safely, the toolkit's VM-URI log line). The pure [parse] decoder turns
/// the matched line into `ResolvedOutputs` entries keyed by [OutputRef.id]
/// — the ephemeral-port pattern, declaratively.
final class HandshakeLine extends Readiness {
  const HandshakeLine({this.pattern, super.budget, this.parse});

  /// The line must match this pattern (when non-null).
  final Pattern? pattern;

  /// Pure decoder: matched line → output values. Must not perform I/O.
  final Map<String, Object?> Function(String line)? parse;

  @override
  String describe() =>
      'handshake line${pattern == null ? '' : ' matching $pattern'}';
}

/// A file that appears when the resource is ready — and, for
/// writer-owned contracts, disappears when it exits: **absence is the
/// liveness signal** (the runner-session spec-v2 rule).
final class FilePresent extends Readiness {
  const FilePresent(this.path, {super.budget, this.absenceIsLiveness = true});

  /// Path whose presence is the readiness (or liveness) signal.
  final String path;

  /// When true (the writer-owned contract shape), the file is removed at
  /// exit and its absence proves the resource ended; the provider owes one
  /// typed secondary probe to confirm presence is current.
  final bool absenceIsLiveness;

  @override
  String describe() => 'file present: $path';
}

/// A log line matching a pattern. The scrape dialect, made declarative:
/// pattern and budget are declared, mechanics stay in the provider.
final class LogPattern extends Readiness {
  const LogPattern(this.pattern, {super.budget});

  final Pattern pattern;

  @override
  String describe() => 'log matching $pattern';
}

/// A TCP endpoint accepting connections.
final class TcpConnect extends Readiness {
  const TcpConnect(this.host, this.port, {super.budget});

  final String host;
  final int port;

  @override
  String describe() => 'tcp connect $host:$port';
}

/// All of the given conditions must hold. Budgets compose: the outer
/// budget (when set) bounds the whole conjunction; unset inner budgets
/// inherit it. Composition-time validation rejects empty and nested
/// conjunctions (flatten instead).
final class ReadinessAll extends Readiness {
  const ReadinessAll(this.conditions, {super.budget});

  final List<Readiness> conditions;

  @override
  String describe() => conditions.map((final c) => c.describe()).join(' AND ');
}

/// Convenience for the common multi-condition conjunctions.
Readiness allOf(
  final Iterable<Readiness> conditions, {
  final Duration? budget,
}) =>
    ReadinessAll(List.of(conditions), budget: budget);
