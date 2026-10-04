/// The client half of the air channel (ADR-0037 §3–4): resolve the plan
/// against the local install, fetch artifacts, verify digests, stage.
/// The runtime apply is lane-specific (reload / staged-next-launch /
/// nextLoad); this layer ends at a staged, verified artifact set and a
/// receipt that distinguishes requested / applied / failed / unknown
/// (ADR-0030 §5).
library;

import 'dart:io';

import 'channel_manifest.dart';
import 'channel_plan.dart';
import 'channel_source.dart';
import 'signing.dart' show verifySignature;
import 'staged_journal.dart' show JournalState, StagedUpdateJournal;

/// One artifact's journey through an apply.
class ApplyStep {
  const ApplyStep({
    required this.revision,
    required this.unit,
    required this.artifact,
    this.status = 'requested',
    this.stagedPath,
    this.error,
  });

  final String revision;
  final String unit;
  final UnitArtifact artifact;

  /// `requested` → `applied` (staged, digest-verified) | `failed`.
  final String status;
  final String? stagedPath;
  final String? error;

  Map<String, Object?> toJson() => {
        'revision': revision,
        'unit': unit,
        'artifact': artifact.toJson(),
        'status': status,
        if (stagedPath != null) 'stagedPath': stagedPath,
        if (error != null) 'error': error,
      };
}

/// The apply receipt.
class UpdateReceipt {
  const UpdateReceipt({
    required this.ok,
    required this.mode,
    required this.fromRevision,
    required this.toRevision,
    this.steps = const [],
    this.snapshotPath,
    this.reasons = const [],
    this.journal,
  });

  final bool ok;

  /// `upToDate` | `chain` | `snapshot` | `refused` | `failed`.
  final String mode;
  final String fromRevision;
  final String toRevision;
  final List<ApplyStep> steps;
  final String? snapshotPath;
  final List<String> reasons;

  /// Set when the apply was journaled under a boot watchdog (G-AC6):
  /// the app's startup beacon decides commit vs rollback.
  final JournalState? journal;

  /// Artifacts that are staged and digest-verified when [ok].
  List<String> get stagedFiles => [
        for (final s in steps)
          if (s.stagedPath != null) s.stagedPath!,
      ];

  Map<String, Object?> toJson() => {
        'ok': ok,
        'mode': mode,
        'fromRevision': fromRevision,
        'toRevision': toRevision,
        'steps': [for (final s in steps) s.toJson()],
        if (snapshotPath != null) 'snapshotPath': snapshotPath,
        'reasons': reasons,
        if (journal != null) 'journal': journal!.toJson(),
      };
}

/// Fetches the channel, resolves the plan, verifies and stages artifacts.
/// Nothing here executes downloaded code — staging hands off to the
/// lane's apply mechanism (e.g. `StagedTarget`, web `nextLoad`).
class UpdateClient {
  const UpdateClient({this.maxTotalBytes = 64 * 1024 * 1024});

  /// Client-side hard ceiling regardless of channel policy.
  final int maxTotalBytes;

  /// Resolves the plan without staging anything.
  Future<ChannelPlan> check(ChannelSource source, LocalInstall local,
      {int? slotBudget}) async {
    final pointer = await source.fetchPointer();
    if (pointer.policy.requiresSignature && pointer.signedBy == null) {
      return ChannelPlan(
        mode: ChannelPlanMode.refused,
        fromRevision: local.appliedRevision ?? 'none',
        toRevision: pointer.revision,
        reasons: [
          'channel policy requiresSignature but the pointer is unsigned (G-AC5)',
        ],
      );
    }
    final anchor = local.trustedPublicKeyHex;
    if (anchor != null) {
      // The install embeds a trust anchor: the pointer AND the head
      // manifest must verify under it — an unsigned channel is as dead as
      // a wrongly-signed one (ADR-0037 §4).
      final pointerVerdict = await verifySignature(pointer.toJson(),
          trustedPublicKeyHex: anchor);
      if (!pointerVerdict.ok) {
        return ChannelPlan(
          mode: ChannelPlanMode.refused,
          fromRevision: local.appliedRevision ?? 'none',
          toRevision: pointer.revision,
          reasons: ['pointer: ${pointerVerdict.reason}'],
        );
      }
    }
    final history = await source.fetchHistory();
    if (anchor != null) {
      final headVerdict = await verifySignature(history.first.toJson(),
          trustedPublicKeyHex: anchor);
      if (!headVerdict.ok) {
        return ChannelPlan(
          mode: ChannelPlanMode.refused,
          fromRevision: local.appliedRevision ?? 'none',
          toRevision: history.first.revision,
          reasons: ['head manifest: ${headVerdict.reason}'],
        );
      }
    }
    if (pointer.policy.requiresSignature &&
        pointer.signedBy != null &&
        anchor == null) {
      return ChannelPlan(
        mode: ChannelPlanMode.refused,
        fromRevision: local.appliedRevision ?? 'none',
        toRevision: pointer.revision,
        reasons: [
          'channel requires signatures but the install has no trust anchor to verify under — embed the publisher public key at build time'
        ],
      );
    }
    return planChain(pointer: pointer, headToBaseline: history, local: local,
        slotBudget: slotBudget);
  }

  /// Resolves, fetches, digest-verifies, and stages the plan's artifacts
  /// under [stageDir]. On any verification failure the receipt fails and
  /// the offending step says why; earlier verified files remain on disk
  /// (the caller owns cleanup) and are reported as applied — the apply is
  /// never implied atomic.
  ///
  /// With a [journal] (G-AC6), a successful apply is journaled into the
  /// boot-watchdog: the set is copied to `staged/`, and the receipt
  /// reports it — the app's startup beacon then decides
  /// `journal.commit()` (promote) vs `journal.rollback()` (discard,
  /// keep the known-good set). Never bricks.
  Future<UpdateReceipt> apply(
    ChannelSource source,
    LocalInstall local, {
    required String stageDir,
    int? slotBudget,
    StagedUpdateJournal? journal,
  }) async {
    final plan = await check(source, local, slotBudget: slotBudget);
    final from = plan.fromRevision;
    switch (plan.mode) {
      case ChannelPlanMode.upToDate:
        return UpdateReceipt(
            ok: true,
            mode: 'upToDate',
            fromRevision: from,
            toRevision: plan.toRevision);
      case ChannelPlanMode.refused:
        return UpdateReceipt(
            ok: false,
            mode: 'refused',
            fromRevision: from,
            toRevision: plan.toRevision,
            reasons: plan.reasons);
      case ChannelPlanMode.chain:
        final total = plan.bytesTotal;
        if (total > maxTotalBytes) {
          return UpdateReceipt(
              ok: false,
              mode: 'refused',
              fromRevision: from,
              toRevision: plan.toRevision,
              reasons: [
                'chain bytes $total exceed the client ceiling $maxTotalBytes'
              ]);
        }
        final steps = <ApplyStep>[];
        for (final step in plan.steps) {
          final applied = await _fetchVerified(
            source,
            step.artifact,
            step: step,
            stageDir: stageDir,
            name: '${step.unit}-${step.revision}.delta.dill',
          );
          steps.add(applied);
          if (applied.status != 'applied') {
            return UpdateReceipt(
                ok: false,
                mode: 'failed',
                fromRevision: from,
                toRevision: plan.toRevision,
                steps: steps,
                reasons: [
                  'artifact for unit `${step.unit}` at ${step.revision} failed verification: ${applied.error}'
                ]);
          }
        }
        return _done(
            UpdateReceipt(
                ok: true,
                mode: 'chain',
                fromRevision: from,
                toRevision: plan.toRevision,
                steps: steps),
            journal);
      case ChannelPlanMode.snapshot:
        final snapshot = plan.snapshot!;
        final applied = await _fetchVerified(
          source,
          snapshot,
          step: null,
          stageDir: stageDir,
          name: snapshot.artifactName,
        );
        if (applied.status != 'applied') {
          // Stay on the current revision; never brick (ADR-0037 §3.4).
          return UpdateReceipt(
              ok: false,
              mode: 'failed',
              fromRevision: from,
              toRevision: plan.toRevision,
              steps: [applied],
              reasons: [
                'snapshot fetch failed: ${applied.error} — staying on $from'
              ]);
        }
        return _done(
            UpdateReceipt(
                ok: true,
                mode: 'snapshot',
                fromRevision: from,
                toRevision: plan.toRevision,
                steps: [applied],
                snapshotPath: applied.stagedPath),
            journal);
    }
  }

  UpdateReceipt _done(UpdateReceipt receipt, StagedUpdateJournal? journal) {
    if (journal == null || !receipt.ok) return receipt;
    final state = journal.stage(receipt);
    return UpdateReceipt(
        ok: receipt.ok,
        mode: receipt.mode,
        fromRevision: receipt.fromRevision,
        toRevision: receipt.toRevision,
        steps: receipt.steps,
        snapshotPath: receipt.snapshotPath,
        reasons: receipt.reasons,
        journal: state);
  }

  Future<ApplyStep> _fetchVerified(
    ChannelSource source,
    UnitArtifact artifact, {
    required ChainStep? step,
    required String stageDir,
    required String name,
  }) async {
    final stepMeta = ApplyStep(
      revision: step?.revision ?? 'snapshot',
      unit: step?.unit ?? '__snapshot__',
      artifact: artifact,
    );
    try {
      final bytes = await source.fetchArtifact(artifact.file);
      final digest = sha256Hex(bytes);
      if (digest != artifact.sha256) {
        return _failed(
            stepMeta, 'sha256 mismatch: expected ${artifact.sha256}, '
                'got $digest');
      }
      if (bytes.length != artifact.bytes) {
        return _failed(
            stepMeta, 'byte length mismatch: expected ${artifact.bytes}, '
                'got ${bytes.length}');
      }
      final path = '$stageDir/$name';
      File(path)
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes, flush: true);
      return ApplyStep(
        revision: stepMeta.revision,
        unit: stepMeta.unit,
        artifact: artifact,
        status: 'applied',
        stagedPath: path,
      );
    } on ChannelSourceException catch (e) {
      return _failed(stepMeta, e.message);
    }
  }

  ApplyStep _failed(ApplyStep step, String error) => ApplyStep(
        revision: step.revision,
        unit: step.unit,
        artifact: step.artifact,
        status: 'failed',
        error: error,
      );
}
