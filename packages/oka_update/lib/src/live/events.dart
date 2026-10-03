/// Event ladder for a live patch run (ADR-0034 P2). Every step of a
/// [LivePatchSession] emits one event; the stream IS the debug surface —
/// a run is explainable without a debugger.
library;

enum LivePatchPhase {
  /// Eligibility checked (manifests given) or skipped (none given).
  planned,

  /// Source files rewritten on disk.
  patched,

  /// Unit delta produced by the injected compiler.
  compiled,

  /// Delta handed to a target (pre-apply).
  applying,

  /// Target acknowledged the apply (wire report attached).
  applied,

  /// Target connected; baseline probe values captured (pre-patch).
  connected,

  /// Probe re-evaluated after apply.
  verified,

  /// Session refused before touching any target.
  refused,

  /// A step failed; `details['error']` carries the message.
  failed,
}

/// One observable step of a live patch. [details] is free-form but stable
/// keys are used by [LivePatchReceipt.describe]: `bytes`, `durationMs`,
/// `mode`, `error`, `before`, `after`, `target`, `unit`.
class LivePatchEvent {
  LivePatchEvent({
    required this.phase,
    this.targetId,
    this.unit,
    this.details = const {},
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final LivePatchPhase phase;

  /// Target the event belongs to (null for session-level phases).
  final String? targetId;

  /// Patch unit the event belongs to.
  final String? unit;

  final Map<String, Object?> details;
  final DateTime at;

  /// One-line human explanation — the `oka why` of this event.
  String get why {
    final where = targetId == null ? '' : '[$targetId] ';
    switch (phase) {
      case LivePatchPhase.planned:
        return '${where}eligibility: ${details['patchable'] == true ? 'patchable' : 'refused — ${details['reasons']}'}';
      case LivePatchPhase.patched:
        return '${where}wrote ${details['files']} patch file(s) on disk';
      case LivePatchPhase.compiled:
        return '${where}unit delta ${details['bytes']} bytes at ${details['path']}';
      case LivePatchPhase.applying:
        return '${where}applying delta via ${details['mode']}';
      case LivePatchPhase.applied:
        return '${where}applied in ${details['durationMs']} ms (${details['mode']})';
      case LivePatchPhase.connected:
        return '${where}connected; ${details['probes']} baseline probe(s) captured';
      case LivePatchPhase.verified:
        return '${where}probe `${details['probe']}`: ${details['before']} -> ${details['after']}'
                '${details['held'] == true ? ' (held — no restart)' : ''}';
      case LivePatchPhase.refused:
        return '${where}refused: ${details['reason']}';
      case LivePatchPhase.failed:
        return '${where}failed: ${details['error']}';
    }
  }

  Map<String, Object?> toJson() => {
        'phase': phase.name,
        if (targetId != null) 'target': targetId,
        if (unit != null) 'unit': unit,
        'at': at.toIso8601String(),
        'details': details,
      };

  @override
  String toString() => 'live[${phase.name}] $why';
}
