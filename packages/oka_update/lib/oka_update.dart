/// Authoring and planner surface for declarative patch units (ADR-0031).
///
/// Units are declared values — never code annotations. Eligibility is
/// computed from revision manifests, never assumed: a patch is only planned
/// when every affected unit's contract fingerprint is unchanged and the unit
/// set is structural-identical.
///
/// The `live` surface (ADR-0034 P2) applies a planned patch to running
/// programs across platforms: one VM-service wire carries it to native JIT
/// (stock VM, flutter desktop via DDS, flutter devices via DevFS) and to
/// DDC/DDK web (dwds implements the same protocol); AOT/restart lanes are
/// staged, never implied.
library;

export 'src/channel/channel_manifest.dart';
export 'src/channel/channel_plan.dart';
export 'src/channel/channel_source.dart';
export 'src/channel/git_target.dart';
export 'src/channel/ship.dart';
export 'src/channel/signing.dart';
export 'src/channel/staged_journal.dart';
export 'src/channel/update_client.dart';
export 'src/live/agent.dart';
export 'src/live/assets.dart';
export 'src/live/events.dart';
export 'src/live/receipt.dart';
export 'src/live/session.dart';
export 'src/live/spec.dart';
export 'src/live/staged_target.dart';
export 'src/live/target.dart';
export 'src/live/verify.dart';
export 'src/live/vm_service_wire.dart';
export 'src/live/vm_target.dart';
export 'src/live/watcher.dart';
export 'src/live/web_target.dart';
export 'src/patch_plan.dart';
export 'src/unit_spec.dart';
