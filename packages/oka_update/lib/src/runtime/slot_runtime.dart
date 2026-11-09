/// The tiny authenticated update handler (ADR-0035 §S2, under the ADR-0030
/// §5 ownership rule: oka plans, delivers and verifies; THE RUNTIME
/// APPLIES). A host AOT server embeds [SlotRuntime] with its generated
/// slot registry's hooks (`oka_dart_kernel`'s slot-registry generator owns
/// the actual flip) plus its trust anchor; oka's runtime envelope applies
/// one S2 operation triple — load unit / swap pointer / receipt — and
/// nothing more: no oka daemon in-process, no second policy engine.
///
/// Honest boundaries: slots are pre-provisioned at build time and bounded
/// per process; envelope replay/freshness policy stays with the embedder
/// (the signature pins content, not time); the artifact digest verifies
/// the bytes already staged by the delivery — the pointer flip follows
/// only on a verified envelope AND a verified artifact.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../channel/channel_manifest.dart';
import '../channel/signing.dart';
import '../channel/slot_envelope.dart' show slotEnvelopeSchemaVersion;

/// A signed, parsed slot-update envelope (shape v1):
/// `{schemaVersion, channel, family, revision, artifact?: {file, sha256,
/// bytes}, issuedAtMs}`.
class SlotUpdateEnvelope {
  const SlotUpdateEnvelope({
    required this.channel,
    required this.family,
    required this.revision,
    required this.issuedAtMs,
    required this.raw,
    this.artifact,
  });

  /// Fail-closed parse: missing or malformed fields throw
  /// [FormatException] — the caller turns that into the
  /// `slot_envelope_malformed` refusal.
  factory SlotUpdateEnvelope.parse(Map<String, Object?> json) {
    if (json['schemaVersion'] != slotEnvelopeSchemaVersion) {
      throw const FormatException('unsupported envelope schemaVersion');
    }
    final channel = json['channel'];
    final family = json['family'];
    final revision = json['revision'];
    final issuedAtMs = json['issuedAtMs'];
    if (channel is! String || family is! String || revision is! String) {
      throw const FormatException(
          'channel, family and revision must be strings');
    }
    if (issuedAtMs is! int) {
      throw const FormatException('issuedAtMs must be an int');
    }
    final artifactJson = json['artifact'];
    UnitArtifact? artifact;
    if (artifactJson != null) {
      if (artifactJson is! Map) {
        throw const FormatException('artifact must be an object');
      }
      artifact = UnitArtifact.fromJson(
          artifactJson.cast<String, dynamic>());
    }
    return SlotUpdateEnvelope(
      channel: channel,
      family: family,
      revision: revision,
      issuedAtMs: issuedAtMs,
      artifact: artifact,
      raw: json,
    );
  }

  /// The channel the envelope rides (`stable`).
  final String channel;

  /// The slot family to flip (`feature`).
  final String family;

  /// The revision to load (`r2`).
  final String revision;

  /// The part artifact the delivery staged for this slot, when the update
  /// carries one. Verified by digest BEFORE any pointer flip.
  final UnitArtifact? artifact;

  final int issuedAtMs;

  /// The full decoded envelope (including `signedBy`), kept for receipts.
  final Map<String, Object?> raw;
}

/// One embeddable slot family: the hooks the host server hands the
/// runtime. The generated registry owns the actual flip — the runtime
/// never touches pointers itself.
class SlotFamilyRuntime {
  const SlotFamilyRuntime({
    required this.revisions,
    required this.load,
    required this.currentRevision,
  });

  /// The provisioned revision ids (bounded per process).
  final Set<String> revisions;

  /// Loads a provisioned revision and flips the registry pointer.
  final Future<void> Function(String revision) load;

  /// The currently loaded revision (`''` before the first load).
  final String Function() currentRevision;
}

/// The runtime's configuration: registry hooks per family plus the trust
/// anchor. `channel` pins the expected envelope channel (`null` accepts
/// any — for embedders that gate channels themselves).
class SlotRuntimeSpec {
  const SlotRuntimeSpec({
    required this.families,
    required this.trustedPublicKeyHex,
    this.channel = 'stable',
  });

  final Map<String, SlotFamilyRuntime> families;

  /// The embedded trust anchor (hex public key) — a different valid key
  /// refuses (`verifySignature`'s pinned-anchor rule).
  final String trustedPublicKeyHex;

  final String? channel;
}

/// The pure decision for one verified envelope (I/O-free, fully tested).
class SlotDecision {
  const SlotDecision(
      {required this.mode, this.refusalCode, this.refusalReason});

  /// `apply` | `already-current` | `refused`.
  final String mode;

  /// Refusal code when [mode] is `refused` (the runtime's honest
  /// vocabulary: a receipt names the why, never a bare failure).
  final String? refusalCode;
  final String? refusalReason;
}

/// Decides what to do with one envelope. Inputs are pre-computed facts:
/// the signature verdict, the family's current revision, and the staged
/// artifact's digest (or `null` when the envelope carries no artifact or
/// the file is missing — `artifactExists` distinguishes those).
SlotDecision decideSlotUpdate({
  required SlotUpdateEnvelope envelope,
  required SignatureVerdict signature,
  required SlotRuntimeSpec spec,
  required String currentRevision,
  required bool artifactExists,
  String? artifactDigest,
}) {
  if (!signature.ok) {
    return SlotDecision(
        mode: 'refused',
        refusalCode: 'slot_envelope_signature_invalid',
        refusalReason: signature.reason);
  }
  if (spec.channel != null && envelope.channel != spec.channel) {
    return SlotDecision(
        mode: 'refused',
        refusalCode: 'slot_channel_unknown',
        refusalReason:
            'envelope channel `${envelope.channel}` != pinned channel '
            '`${spec.channel}`');
  }
  final family = spec.families[envelope.family];
  if (family == null) {
    return SlotDecision(
        mode: 'refused',
        refusalCode: 'slot_family_unknown',
        refusalReason:
            'no provisioned slot family `${envelope.family}` (provisioned: '
            '${spec.families.keys.join(', ')})');
  }
  if (!family.revisions.contains(envelope.revision)) {
    return SlotDecision(
        mode: 'refused',
        refusalCode: 'slot_revision_unknown',
        refusalReason: 'slot `${envelope.family}` has no provisioned '
            'revision `${envelope.revision}` (provisioned: '
            '${family.revisions.join(', ')})');
  }
  if (envelope.artifact != null) {
    if (!artifactExists) {
      return SlotDecision(
          mode: 'refused',
          refusalCode: 'slot_artifact_missing',
          refusalReason:
              'staged artifact `${envelope.artifact!.file}` is missing');
    }
    if (artifactDigest != envelope.artifact!.sha256) {
      return SlotDecision(
          mode: 'refused',
          refusalCode: 'slot_artifact_digest_mismatch',
          refusalReason: 'staged artifact `${envelope.artifact!.file}` '
              'digest $artifactDigest != envelope digest '
              '${envelope.artifact!.sha256}');
    }
  }
  if (envelope.revision == currentRevision) {
    return const SlotDecision(mode: 'already-current');
  }
  return const SlotDecision(mode: 'apply');
}

/// The receipt of one processed envelope (written next to it as
/// `<envelope>.receipt.json`): the apply-side record of what happened,
/// including the refusal vocabulary.
class SlotApplyReceipt {
  const SlotApplyReceipt({
    required this.envelope,
    required this.mode,
    required this.pid,
    required this.appliedAtMs,
    this.family,
    this.from,
    this.to,
    this.refusalCode,
    this.refusalReason,
    this.signedBy,
  });

  factory SlotApplyReceipt.fromJson(Map<String, Object?> json) =>
      SlotApplyReceipt(
        envelope: json['envelope']! as String,
        mode: json['mode']! as String,
        family: json['family'] as String?,
        from: json['from'] as String?,
        to: json['to'] as String?,
        refusalCode: json['refusalCode'] as String?,
        refusalReason: json['refusalReason'] as String?,
        signedBy: json['signedBy'] as Map<String, Object?>?,
        pid: json['pid']! as int,
        appliedAtMs: json['appliedAtMs']! as int,
      );

  /// Envelope file name (not the full path — receipts travel with it).
  final String envelope;
  final String mode;
  final String? family;
  final String? from;
  final String? to;
  final String? refusalCode;
  final String? refusalReason;
  final Map<String, Object?>? signedBy;
  final int pid;
  final int appliedAtMs;

  Map<String, Object?> toJson() => {
        'schemaVersion': slotEnvelopeSchemaVersion,
        'envelope': envelope,
        'mode': mode,
        'family': family,
        'from': from,
        'to': to,
        'refusalCode': refusalCode,
        'refusalReason': refusalReason,
        'signedBy': signedBy,
        'pid': pid,
        'appliedAtMs': appliedAtMs,
      };

  String describe() => refusalCode == null
      ? '$mode: $family $from -> $to'
      : 'refused: $refusalCode — $refusalReason';
}

/// The embedded apply-side handler: verifies, decides, flips (through the
/// host's hooks), and receipts. Bounded work per poll cycle; processed
/// envelopes rename to `<name>.processed` so a crash cannot double-apply
/// silently (an already-current replay receipts `already-current`).
class SlotRuntime {
  SlotRuntime({required this.spec});

  final SlotRuntimeSpec spec;

  /// Applies one envelope file; writes `<path>.receipt.json` next to it
  /// and renames the envelope to `<path>.processed`. Never throws for an
  /// envelope problem — every outcome is a receipt.
  Future<SlotApplyReceipt> applyEnvelopeFile(String path) async {
    final file = File(path);
    final name = path.split(Platform.pathSeparator).last;
    SlotApplyReceipt receipt;
    try {
      receipt = await _apply(name, file);
    } catch (error) {
      receipt = SlotApplyReceipt(
        envelope: name,
        mode: 'refused',
        refusalCode: 'slot_envelope_malformed',
        refusalReason: error.toString(),
        pid: pid,
        appliedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    }
    final dir = file.parent.path;
    File('$dir/$name.receipt.json')
        .writeAsStringSync('${jsonEncode(receipt.toJson())}\n');
    final processed = File('$dir/$name.processed');
    if (processed.existsSync()) processed.deleteSync();
    try {
      file.renameSync('$dir/$name.processed');
    } on FileSystemException {
      // The envelope vanished under us — the receipt still records this
      // cycle's outcome.
    }
    return receipt;
  }

  Future<SlotApplyReceipt> _apply(String name, File file) async {
    Map<String, Object?> json;
    try {
      json = (jsonDecode(file.readAsStringSync()) as Map)
          .cast<String, Object?>();
    } on FormatException catch (error) {
      return _refused(name, 'slot_envelope_malformed', error.message);
    }
    final signature = await verifySignature(json,
        trustedPublicKeyHex: spec.trustedPublicKeyHex);
    SlotUpdateEnvelope envelope;
    try {
      envelope = SlotUpdateEnvelope.parse(json);
    } on FormatException catch (error) {
      return _refused(name, 'slot_envelope_malformed', error.message,
          signedBy: json['signedBy'] as Map<String, Object?>?);
    }
    final decision = decideSlotUpdate(
      envelope: envelope,
      signature: signature,
      spec: spec,
      currentRevision: _safeCurrentRevision(envelope.family),
      artifactExists: envelope.artifact != null &&
          File(_artifactPath(file.parent.path, envelope.artifact!.file))
              .existsSync(),
      artifactDigest: envelope.artifact == null
          ? null
          : _digestOr(
              _artifactPath(file.parent.path, envelope.artifact!.file)),
    );
    final signedBy = json['signedBy'] as Map<String, Object?>?;
    switch (decision.mode) {
      case 'refused':
        return SlotApplyReceipt(
          envelope: name,
          mode: 'refused',
          family: envelope.family,
          from: spec.families.containsKey(envelope.family)
              ? _safeCurrentRevision(envelope.family)
              : null,
          to: envelope.revision,
          refusalCode: decision.refusalCode,
          refusalReason: decision.refusalReason,
          signedBy: signedBy,
          pid: pid,
          appliedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
      case 'already-current':
        return SlotApplyReceipt(
          envelope: name,
          mode: 'already-current',
          family: envelope.family,
          from: envelope.revision,
          to: envelope.revision,
          signedBy: signedBy,
          pid: pid,
          appliedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
    }
    final from = _safeCurrentRevision(envelope.family);
    try {
      await spec.families[envelope.family]!.load(envelope.revision);
    } catch (error) {
      return SlotApplyReceipt(
        envelope: name,
        mode: 'refused',
        family: envelope.family,
        from: from,
        to: envelope.revision,
        refusalCode: 'slot_load_failed',
        refusalReason: error.toString(),
        signedBy: signedBy,
        pid: pid,
        appliedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    }
    return SlotApplyReceipt(
      envelope: name,
      mode: 'slot-swap',
      family: envelope.family,
      from: from,
      to: envelope.revision,
      signedBy: signedBy,
      pid: pid,
      appliedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  SlotApplyReceipt _refused(String name, String code, String reason,
          {Map<String, Object?>? signedBy}) =>
      SlotApplyReceipt(
        envelope: name,
        mode: 'refused',
        refusalCode: code,
        refusalReason: reason,
        signedBy: signedBy,
        pid: pid,
        appliedAtMs: DateTime.now().millisecondsSinceEpoch,
      );

  String _safeCurrentRevision(String family) {
    final familyRuntime = spec.families[family];
    if (familyRuntime == null) return '';
    try {
      return familyRuntime.currentRevision();
    } catch (_) {
      return '';
    }
  }

  String _artifactPath(String dir, String relative) {
    final cleaned = relative.replaceAll(r'\', '/');
    if (cleaned.startsWith('/') || cleaned.contains('..')) {
      throw const FormatException(
          'artifact file must be a relative path without `..`');
    }
    return '$dir/$cleaned';
  }

  String? _digestOr(String path) {
    try {
      return sha256File(path);
    } on FileSystemException {
      return null;
    }
  }

  /// The watch loop: processes at most [maxPerCycle] envelopes per cycle,
  /// then sleeps [pollInterval]. Runs until [until] returns true (checked
  /// between cycles). Envelope files are every `*.json` in [dir] whose
  /// name does not end in `.receipt.json`.
  Future<void> watchDirectory(
    String dir, {
    Duration pollInterval = const Duration(milliseconds: 200),
    bool Function()? until,
    int maxPerCycle = 8,
    void Function(SlotApplyReceipt receipt)? onReceipt,
  }) async {
    final directory = Directory(dir);
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    while (until?.call() != true) {
      var processed = 0;
      final pending = directory
          .listSync()
          .whereType<File>()
          .where((file) =>
              file.path.endsWith('.json') &&
              !file.path.endsWith('.receipt.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in pending) {
        if (processed >= maxPerCycle) break;
        final receipt = await applyEnvelopeFile(file.path);
        onReceipt?.call(receipt);
        processed++;
      }
      if (processed == 0) {
        await Future<void>.delayed(pollInterval);
      }
    }
  }
}
