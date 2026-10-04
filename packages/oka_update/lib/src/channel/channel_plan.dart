/// Chain resolution (ADR-0037 §3): given the channel head and a client's
/// install state, produce the ordered apply plan — a chain of unit deltas,
/// a head snapshot, an up-to-date short-circuit, or a typed refusal.
/// Pure: no I/O, fully table-tested; the store-boundary and threshold
/// rules live here so every client enforces the same policy.
library;

import 'channel_manifest.dart';

/// How the client should apply the channel head.
enum ChannelPlanMode { upToDate, chain, snapshot, refused }

/// One applyable hop: one unit's delta at one revision.
class ChainStep {
  const ChainStep({
    required this.revision,
    required this.unit,
    required this.artifact,
  });

  final String revision;
  final String unit;
  final UnitArtifact artifact;
}

/// The resolved plan. [mode] == refused ⇒ [reasons] names the fix.
class ChannelPlan {
  const ChannelPlan({
    required this.mode,
    required this.fromRevision,
    required this.toRevision,
    this.steps = const [],
    this.snapshot,
    this.bytesTotal = 0,
    this.reasons = const [],
  });

  final ChannelPlanMode mode;

  /// The revision the client is on when the plan starts.
  final String fromRevision;

  /// The channel head the plan resolves to.
  final String toRevision;
  final List<ChainStep> steps;

  /// Head snapshot artifact when [mode] == snapshot.
  final UnitArtifact? snapshot;

  /// Cumulative artifact bytes of [steps].
  final int bytesTotal;
  final List<String> reasons;

  bool get ok => mode != ChannelPlanMode.refused;

  Map<String, Object?> toJson() => {
        'mode': mode.name,
        'fromRevision': fromRevision,
        'toRevision': toRevision,
        'steps': [
          for (final s in steps)
            {
              'revision': s.revision,
              'unit': s.unit,
              'artifact': s.artifact.toJson(),
            }
        ],
        'snapshot': snapshot?.toJson(),
        'bytesTotal': bytesTotal,
        'reasons': reasons,
      };
}

/// The client install state: the app-binary revision it was built from,
/// the patch revision it currently has applied (null when none), and the
/// embedded trust anchor (G-AC5) — when present, unsigned or wrongly
/// signed channels refuse.
class LocalInstall {
  const LocalInstall({
    required this.baseline,
    this.appliedRevision,
    this.trustedPublicKeyHex,
  });

  final String baseline;
  final String? appliedRevision;

  /// The ed25519 public key embedded in the app binary at build time.
  final String? trustedPublicKeyHex;
}

/// Resolves how a client at [local] reaches the channel head under
/// [pointer]'s policy. [headToBaseline] is the channel history, head
/// first — the source materializes it by walking `parent` links and
/// fetching each manifest. This function is the single policy point:
/// store boundaries, thresholds, and the snapshot fallback all live here.
///
/// A hard ceiling ([slotBudget]) may cap the chain below the publisher
/// policy (AOT slot budgets are per-process, ADR-0035 §2d).
ChannelPlan planChain({
  required ChannelPointer pointer,
  required List<RevisionNode> headToBaseline,
  required LocalInstall local,
  int? slotBudget,
}) {
  if (headToBaseline.isEmpty) {
    throw ArgumentError('headToBaseline must contain at least the head node');
  }
  final head = headToBaseline.first;
  final segment = <RevisionNode>[];
  var foundApplied = false;
  var reachedBaseline = false;
  for (final node in headToBaseline) {
    if (local.appliedRevision != null &&
        node.revision == local.appliedRevision) {
      foundApplied = true;
      break;
    }
    segment.add(node);
    if (node.parent == null) {
      reachedBaseline = true;
      break;
    }
  }
  // A never-patched install anchors at the baseline seed — but only when
  // that seed IS the client's binary; otherwise the refusals below fire.
  if (!foundApplied && reachedBaseline) {
    final baselineNode = segment.last;
    if (local.appliedRevision == null &&
        baselineNode.revision == local.baseline) {
      foundApplied = true;
    }
  }

  // The walk ended without the client's position: either the applied
  // revision is foreign to this channel (pruned, forked), or the walk
  // reached the baseline seed — which only starts a chain when it IS the
  // client's binary.
  if (!foundApplied) {
    final baselineNode = segment.last;
    if (local.appliedRevision != null) {
      return ChannelPlan(
        mode: ChannelPlanMode.refused,
        fromRevision: local.appliedRevision!,
        toRevision: head.revision,
        reasons: [
          'applied revision `${local.appliedRevision}` not found in channel history — snapshot or store lane required',
        ],
      );
    }
    if (baselineNode.revision != local.baseline) {
      return ChannelPlan(
        mode: ChannelPlanMode.refused,
        fromRevision: 'none',
        toRevision: head.revision,
        reasons: [
          'channel baseline `${baselineNode.revision}` does not match install baseline `${local.baseline}` — store lane required',
        ],
      );
    }
  }

  return _resolve(
    pointer: pointer,
    head: head,
    local: local,
    segment: segment,
    foundApplied: true,
    reachedBaseline: reachedBaseline,
    slotBudget: slotBudget,
  );
}

ChannelPlan _resolve({
  required ChannelPointer pointer,
  required RevisionNode head,
  required LocalInstall local,
  required List<RevisionNode> segment,
  required bool foundApplied,
  required bool reachedBaseline,
  required int? slotBudget,
}) {
  final policy = pointer.policy;
  if (head.revision == local.appliedRevision) {
    return ChannelPlan(
      mode: ChannelPlanMode.upToDate,
      fromRevision: local.appliedRevision!,
      toRevision: head.revision,
    );
  }

  final from = local.appliedRevision ?? local.baseline;
  if (segment.isEmpty) {
    return ChannelPlan(
      mode: ChannelPlanMode.upToDate,
      fromRevision: from,
      toRevision: head.revision,
    );
  }

  // Store boundaries: a non-patchable node inside the segment cannot be
  // crossed by chaining (its diff needs a store release first).
  final boundary = segment.where((n) => n.plan != null && !n.plan!.patchable);
  final reasons = <String>[];
  if (boundary.isNotEmpty) {
    reasons.add(
        'revision(s) ${boundary.map((n) => n.revision).join(', ')} are store '
        'boundaries (${boundary.first.plan!.reasons.join('; ')}) — chaining '
        'past them is impossible');
  }

  // The baseline seed (parent == null) is the client's own binary, not a
  // patch — it never contributes a step or a threshold revision.
  final patchNodes = segment.where((n) => n.parent != null).toList();

  final steps = <ChainStep>[];
  for (final node in patchNodes.reversed) {
    final units = node.units;
    if (units.isEmpty) continue;
    for (final entry in units.entries) {
      final delta = entry.value.delta;
      if (delta == null) continue;
      steps.add(ChainStep(
          revision: node.revision, unit: entry.key, artifact: delta));
    }
  }
  final bytesTotal = steps.fold(0, (sum, s) => sum + s.artifact.bytes);
  final revisionCount = patchNodes.length;

  // Nothing applyable between the client's position and head (only the
  // baseline seed, or patch revisions that carry no delta): up-to-date.
  if (steps.isEmpty && reasons.isEmpty) {
    return ChannelPlan(
      mode: ChannelPlanMode.upToDate,
      fromRevision: from,
      toRevision: head.revision,
    );
  }

  final overBytes = bytesTotal > policy.maxChainBytes;
  final overLength = revisionCount > policy.maxChainRevisions;
  final overSlot =
      slotBudget != null && revisionCount > slotBudget;
  final snapshotFallback =
      reasons.isNotEmpty || overBytes || overLength || overSlot;

  if (!snapshotFallback) {
    return ChannelPlan(
      mode: ChannelPlanMode.chain,
      fromRevision: from,
      toRevision: head.revision,
      steps: steps,
      bytesTotal: bytesTotal,
    );
  }

  if (overBytes) {
    reasons.add('chain bytes $bytesTotal exceed policy maxChainBytes '
        '${policy.maxChainBytes}');
  }
  if (overLength) {
    reasons.add('chain length $revisionCount exceeds policy '
        'maxChainRevisions ${policy.maxChainRevisions}');
  }
  if (overSlot) {
    reasons.add('chain length $revisionCount exceeds the target slot '
        'budget $slotBudget');
  }

  final snapshot = head.snapshot;
  if (snapshot == null) {
    reasons.add('head revision `${head.revision}` has no snapshot artifact '
        '— publish with `oka ship --snapshot <file>` to serve clients that '
        'cannot chain');
    return ChannelPlan(
      mode: ChannelPlanMode.refused,
      fromRevision: from,
      toRevision: head.revision,
      bytesTotal: bytesTotal,
      reasons: reasons,
    );
  }
  return ChannelPlan(
    mode: ChannelPlanMode.snapshot,
    fromRevision: from,
    toRevision: head.revision,
    snapshot: snapshot,
    bytesTotal: bytesTotal,
    reasons: reasons,
  );
}
