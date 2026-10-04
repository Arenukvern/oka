/// The air channel model (ADR-0037 §2): a content-addressed tree plus a
/// small pointer file, materializable on any dumb static host. Oka never
/// serves traffic; the pointer pins the head revision and the policy the
/// client enforces. Artifact digests (sha256) are mandatory from day one;
/// the signature slot is typed so G-AC5 lands without a format break.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Schema version of the pointer and revision-node wire format.
const int channelSchemaVersion = 2;

/// Canonical JSON: keys sorted recursively so byte-level hashes/signatures
/// are stable across publishers.
String canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    final body =
        keys.map((k) => '"$k":${canonicalJson(value[k])}').join(',');
    return '{$body}';
  }
  if (value is List) return '[${value.map(canonicalJson).join(',')}]';
  return jsonEncode(value);
}

/// sha256 of a byte list, hex-encoded.
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// sha256 of a file's bytes, hex-encoded.
String sha256File(String path) => sha256Hex(File(path).readAsBytesSync());

/// Publisher-side resolution policy, enforced by every client with hard
/// ceilings of its own (ADR-0037 §3).
class ChannelPolicy {
  const ChannelPolicy({
    this.maxChainBytes = defaultMaxChainBytes,
    this.maxChainRevisions = defaultMaxChainRevisions,
    this.requiresSignature = false,
  });

  factory ChannelPolicy.fromJson(Map<String, dynamic> json) => ChannelPolicy(
        maxChainBytes: switch (json['maxChainBytes']) {
          final int v => v,
          _ => defaultMaxChainBytes,
        },
        maxChainRevisions: switch (json['maxChainRevisions']) {
          final int v => v,
          _ => defaultMaxChainRevisions,
        },
        requiresSignature: json['requiresSignature'] == true,
      );

  static const int defaultMaxChainBytes = 512 * 1024;
  static const int defaultMaxChainRevisions = 8;

  /// Cumulative artifact bytes above which a client resolves to the head
  /// snapshot instead of chaining.
  final int maxChainBytes;

  /// Chain length above which a client resolves to the head snapshot
  /// (also the AOT slot-budget guard).
  final int maxChainRevisions;

  /// When true, clients refuse channels whose pointer is unsigned
  /// (G-AC5 enforces signature verification; until then this refuses).
  final bool requiresSignature;

  Map<String, Object?> toJson() => {
        'maxChainBytes': maxChainBytes,
        'maxChainRevisions': maxChainRevisions,
        'requiresSignature': requiresSignature,
      };
}

/// One content-addressed artifact in the channel tree. [file] is relative
/// to the channel root (`artifacts/…`).
class UnitArtifact {
  const UnitArtifact({
    required this.file,
    required this.sha256,
    required this.bytes,
  });

  factory UnitArtifact.fromJson(Map<String, dynamic> json) => UnitArtifact(
        file: json['file'] as String,
        sha256: json['sha256'] as String,
        bytes: json['bytes'] as int,
      );

  final String file;
  final String sha256;
  final int bytes;

  /// The artifact's identity in the content-addressed tree.
  String get artifactName => file.split('/').last;

  Map<String, Object?> toJson() =>
      {'file': file, 'sha256': sha256, 'bytes': bytes};
}

/// A changed unit inside a revision node: its delta (JIT lanes) and,
/// when the publisher provides one, its AOT part artifact.
class RevisionUnit {
  const RevisionUnit({this.delta, this.aotPart});

  factory RevisionUnit.fromJson(Map<String, dynamic> json) => RevisionUnit(
        delta: json['delta'] == null
            ? null
            : UnitArtifact.fromJson(
                (json['delta'] as Map<Object?, Object?>)
                    .cast<String, dynamic>()),
        aotPart: json['aotPart'] == null
            ? null
            : UnitArtifact.fromJson(
                (json['aotPart'] as Map<Object?, Object?>)
                    .cast<String, dynamic>()),
      );

  final UnitArtifact? delta;
  final UnitArtifact? aotPart;

  Map<String, Object?> toJson() => {
        if (delta != null) 'delta': delta!.toJson(),
        if (aotPart != null) 'aotPart': aotPart!.toJson(),
      };
}

/// The signed pointer (ADR-0037 §2): channel name, head revision, policy,
/// signature slot. Lives at the channel root as `pointer.json`.
class ChannelPointer {
  const ChannelPointer({
    required this.channel,
    required this.revision,
    this.policy = const ChannelPolicy(),
    this.signedBy,
  });

  factory ChannelPointer.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw FormatException(
          'unsupported channel pointer schemaVersion: ${json['schemaVersion']}');
    }
    return ChannelPointer(
      channel: json['channel'] as String,
      revision: json['revision'] as String,
      policy: json['policy'] == null
          ? const ChannelPolicy()
          : ChannelPolicy.fromJson(
              (json['policy'] as Map<Object?, Object?>)
                  .cast<String, dynamic>()),
      signedBy: json['signedBy'] == null
          ? null
          : (json['signedBy'] as Map<Object?, Object?>)
              .cast<String, dynamic>(),
    );
  }

  static const int schemaVersion = channelSchemaVersion;

  final String channel;
  final String revision;
  final ChannelPolicy policy;

  /// `{keyId, algorithm, signature}` when signed; null until G-AC5.
  final Map<String, Object?>? signedBy;

  /// Canonical bytes — the signature payload once G-AC5 lands.
  String canonicalBytes() => canonicalJson(toJson());

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'channel': channel,
        'revision': revision,
        'policy': policy.toJson(),
        'signedBy': signedBy,
      };
}

/// The eligibility verdict recorded on a node at publish time
/// (the `planRevisions` outcome, frozen).
class RecordedPlan {
  const RecordedPlan({
    required this.patchable,
    required this.changedUnits,
    required this.coreChanged,
    required this.reasons,
  });

  factory RecordedPlan.fromJson(Map<String, dynamic> json) => RecordedPlan(
        patchable: json['patchable'] == true,
        changedUnits:
            (json['changedUnits'] as List<Object?>? ?? const []).cast<String>(),
        coreChanged: json['coreChanged'] == true,
        reasons:
            (json['reasons'] as List<Object?>? ?? const []).cast<String>(),
      );

  final bool patchable;
  final List<String> changedUnits;
  final bool coreChanged;
  final List<String> reasons;

  Map<String, Object?> toJson() => {
        'patchable': patchable,
        'changedUnits': changedUnits,
        'coreChanged': coreChanged,
        'reasons': reasons,
      };
}

/// One published revision in the channel: its parent, its eligibility
/// verdict (recorded at publish time — the client never re-derives it),
/// its per-library digests (the persisted input every later eligibility
/// diff consumes), and its artifacts. A node with a null [plan] is the
/// baseline seed (the store build's revision); a node whose plan is not
/// patchable is a store boundary chains cannot cross (ADR-0037 §3).
class RevisionNode {
  const RevisionNode({
    required this.revision,
    required this.parent,
    required this.baseline,
    required this.units,
    required this.libraries,
    required this.fingerprints,
    required this.coreFingerprint,
    this.plan,
    this.snapshot,
    this.coreArtifacts = const [],
    this.signedBy,
  });

  factory RevisionNode.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw FormatException(
          'unsupported revision node schemaVersion: ${json['schemaVersion']}');
    }
    return RevisionNode(
      revision: json['revision'] as String,
      parent: json['parent'] as String?,
      baseline: json['baseline'] as String,
      plan: json['plan'] == null
          ? null
          : RecordedPlan.fromJson(
              (json['plan'] as Map<Object?, Object?>).cast<String, dynamic>()),
      coreFingerprint: json['coreFingerprint'] as String,
      units: (json['units'] as Map<Object?, Object?>? ?? const {})
              .cast<String, dynamic>()
          .map((k, v) => MapEntry(
              k,
              RevisionUnit.fromJson(
                  (v as Map<Object?, Object?>).cast<String, dynamic>()))),
      libraries: (json['libraries'] as Map<Object?, Object?>? ?? const {})
              .cast<String, dynamic>()
          .map((k, v) => MapEntry(
              k,
              (v as Map<Object?, Object?>)
                  .cast<String, dynamic>()
                  .map((path, sha) => MapEntry(path, sha as String)))),
      fingerprints: (json['fingerprints'] as Map<Object?, Object?>? ?? const {})
              .cast<String, dynamic>()
          .cast<String, String>(),
      snapshot: json['snapshot'] == null
          ? null
          : UnitArtifact.fromJson(
              (json['snapshot'] as Map<Object?, Object?>)
                  .cast<String, dynamic>()),
      coreArtifacts: (json['coreArtifacts'] as List<Object?>? ?? const [])
          .cast<Map<Object?, Object?>>()
          .map((a) => UnitArtifact.fromJson(a.cast<String, dynamic>()))
          .toList(),
      signedBy: json['signedBy'] == null
          ? null
          : (json['signedBy'] as Map<Object?, Object?>)
              .cast<String, dynamic>(),
    );
  }

  static const int schemaVersion = channelSchemaVersion;

  final String revision;

  /// Previous published revision; null only for the baseline seed.
  final String? parent;

  /// The app-binary revision this patchable segment grows from.
  final String baseline;

  /// Recorded eligibility verdict; null on the baseline seed.
  final RecordedPlan? plan;

  final Map<String, RevisionUnit> units;

  /// Per-unit library digests at this revision (unit → path → sha256).
  final Map<String, Map<String, String>> libraries;

  /// Per-unit contract fingerprints at this revision (unit → sha256).
  final Map<String, String> fingerprints;

  final String coreFingerprint;

  /// Whole-revision artifact (AOT snapshot set) for the snapshot lane.
  final UnitArtifact? snapshot;

  /// Core-level artifacts a node carries for retransfer accounting
  /// (e.g. the web core chunk). Unset in the common patch case.
  final List<UnitArtifact> coreArtifacts;

  /// `{keyId, algorithm, publicKey, signature}` when signed (G-AC5);
  /// the signature covers the canonical JSON of the node without this
  /// field.
  final Map<String, Object?>? signedBy;

  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'revision': revision,
        'parent': parent,
        'baseline': baseline,
        'plan': plan?.toJson(),
        'coreFingerprint': coreFingerprint,
        'units': {for (final e in units.entries) e.key: e.value.toJson()},
        'libraries': libraries,
        'fingerprints': fingerprints,
        'snapshot': snapshot?.toJson(),
        'coreArtifacts': [for (final a in coreArtifacts) a.toJson()],
        'signedBy': signedBy,
      };
}
