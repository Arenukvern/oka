/// Computed eligibility between two revision manifests (ADR-0031 §3):
/// a patch is planned only when it can be proven applicable; unsupported
/// changes produce an explicit alternative, never an implied success.
library;

/// Revision manifest (generator output; shape v1):
/// `{ schemaVersion, revision, coreFingerprint, units: { id: {
///   libraries: { path: { sha256 } }, contractFingerprint } } }`.
typedef RevisionManifest = Map<String, dynamic>;

class PatchPlan {
  const PatchPlan({
    required this.base,
    required this.next,
    required this.patchable,
    required this.changedUnits,
    required this.coreChanged,
    required this.reasons,
  });

  final String? base;
  final String? next;

  /// True when every diff is provably applicable as a store-free patch.
  final bool patchable;

  /// Units whose body changed while their contract fingerprint held.
  final List<String> changedUnits;

  /// True when the core fingerprint moved (core retransfer required).
  final bool coreChanged;

  /// Human/agent-readable refusal reasons; empty when [patchable].
  final List<String> reasons;

  /// The explicit alternative lane when not patchable.
  String? get alternative => patchable ? null : 'full release via store lane';

  Map<String, Object?> toJson() => {
        'base': base,
        'next': next,
        'patchable': patchable,
        'changedUnits': changedUnits,
        'coreChanged': coreChanged,
        'transfer': patchable
            ? 'changed unit chunks + core (embedded hash-table delta)'
            : null,
        'alternative': alternative,
        'reasons': reasons,
      };
}

PatchPlan planRevisions(RevisionManifest base, RevisionManifest next) {
  final baseUnits =
      (base['units'] as Map? ?? const {}).cast<String, dynamic>();
  final nextUnits =
      (next['units'] as Map? ?? const {}).cast<String, dynamic>();

  final changed = <String>[];
  final reasons = <String>[];
  var patchable = true;

  for (final id in {...baseUnits.keys, ...nextUnits.keys}) {
    final b = baseUnits[id] as Map<String, dynamic>?;
    final n = nextUnits[id] as Map<String, dynamic>?;
    if (b == null || n == null) {
      patchable = false;
      reasons
          .add('unit `$id` ${b == null ? 'added' : 'removed'} — structural change');
      continue;
    }
    if (b['libraries'].toString() == n['libraries'].toString()) continue;
    if (b['contractFingerprint'] == n['contractFingerprint']) {
      changed.add(id);
    } else {
      patchable = false;
      reasons.add('unit `$id` contract fingerprint changed');
    }
  }

  return PatchPlan(
    base: base['revision'] as String?,
    next: next['revision'] as String?,
    patchable: patchable,
    changedUnits: changed,
    coreChanged: base['coreFingerprint'] != next['coreFingerprint'],
    reasons: reasons,
  );
}
