/// Slot-swap eligibility (ADR-0035 §S2): composes the frozen
/// [planRevisions] verdict with the slot registry's provisioned reality.
/// A body-only unit change is slot-eligible only when the unit has a
/// provisioned revision slot for the target revision AND the per-process
/// slot budget holds — an eligible plan delivers an envelope for the
/// embedded runtime; an ineligible one names the reason and the full
/// release alternative, never an implied success.
library;

import 'channel/channel_manifest.dart' show ChannelPolicy;
import 'patch_plan.dart';

/// The plan outcome for one base→next revision pair over provisioned
/// slots. [patch] is the frozen [planRevisions] verdict; [slotEligible]
/// adds the S2 constraints on top of it.
class SlotSwapPlan {
  const SlotSwapPlan({
    required this.patch,
    required this.slotEligible,
    required this.unitSlots,
    required this.reasons,
  });

  /// The composed `planRevisions` outcome (untouched — the air channel
  /// freezes this shape into revision nodes).
  final PatchPlan patch;

  /// True when [patch] is patchable AND every changed unit has a
  /// provisioned target slot AND the slot budget holds.
  final bool slotEligible;

  /// Changed unit -> full target slot id (`feature` -> `feature_r2`).
  /// Only eligible units appear.
  final Map<String, String> unitSlots;

  /// Why [slotEligible] is false (empty when true); carries [PatchPlan]'s
  /// reasons too.
  final List<String> reasons;

  /// The explicit alternative when not eligible (the patch's own
  /// alternative, or the S2-specific full-release lane).
  String? get alternative =>
      slotEligible ? null : (patch.alternative ?? 'full release via store lane');

  Map<String, Object?> toJson() => {
        'base': patch.base,
        'next': patch.next,
        'patchable': patch.patchable,
        'slotEligible': slotEligible,
        'unitSlots': unitSlots,
        'coreChanged': patch.coreChanged,
        'alternative': alternative,
        'reasons': reasons,
      };
}

/// Plans the slot-swap lane for [base] -> [next].
///
/// [unitTargets] names the publisher's chosen target revision per changed
/// unit (`feature` -> `r2`). [provisionedSlots] is the slot registry's
/// reality: unit -> provisioned revision ids — what was compiled into the
/// running program. [maxSlotsPerProcess] defaults to the air channel's
/// chain-revision ceiling (the ADR-0037 slot-budget guard).
SlotSwapPlan planSlotSwap(
  RevisionManifest base,
  RevisionManifest next, {
  required Map<String, String> unitTargets,
  required Map<String, Set<String>> provisionedSlots,
  int maxSlotsPerProcess = ChannelPolicy.defaultMaxChainRevisions,
}) {
  final patch = planRevisions(base, next);
  final reasons = [...patch.reasons];
  final unitSlots = <String, String>{};
  if (patch.patchable) {
    for (final unit in patch.changedUnits) {
      final provisioned = provisionedSlots[unit];
      if (provisioned == null || provisioned.isEmpty) {
        reasons.add('unit `$unit` has no provisioned slot registry');
        continue;
      }
      if (provisioned.length > maxSlotsPerProcess) {
        reasons.add('unit `$unit` exceeds the per-process slot budget '
            '(${provisioned.length} > $maxSlotsPerProcess)');
        continue;
      }
      final target = unitTargets[unit];
      if (target == null) {
        reasons.add('unit `$unit` names no target revision slot');
        continue;
      }
      if (!provisioned.contains(target)) {
        reasons.add('unit `$unit` target revision `$target` is not '
            'provisioned (provisioned: ${provisioned.join(', ')})');
        continue;
      }
      unitSlots[unit] = '${unit}_$target';
    }
  }
  return SlotSwapPlan(
    patch: patch,
    slotEligible: patch.patchable && unitSlots.length == patch.changedUnits.length,
    unitSlots: unitSlots,
    reasons: reasons,
  );
}
