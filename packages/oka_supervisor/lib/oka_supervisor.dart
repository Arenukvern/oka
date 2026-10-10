/// Declarative supervisor (ADR-0040): steady-state convergence over the
/// `resource_composition` substrate.
///
/// Declare desired state as typed specs, run [Supervisor.converge] to
/// observe → diff → act once, and read the JSONL facts. The substrate
/// keeps every contract (validation, readiness, events, evidence); this
/// package adds only the policy layer: budgeted restarts, cession-based
/// ownership, and the advisory machine registry.
library;

export 'src/codec.dart';
export 'src/codemap_projection.dart';
export 'src/converge.dart';
export 'src/planner.dart';
export 'src/registry.dart';
export 'src/spec.dart';
export 'src/spec_store.dart';
export 'src/status.dart';
