/// Kernel-graph machinery for declarative patch units (ADR-0032): the
/// runCompiler-shaped pipeline as a library plus the live-patch toolchain
/// (pinned checkout resolution, AOT pipeline exe, per-unit delta compiler).
///
/// The authoring/planner surface lives in `oka_update`; this package owns
/// the mechanics.
library;

export 'src/command_lane.dart';
export 'src/live_pipeline.dart';
export 'src/unit_graph.dart';
