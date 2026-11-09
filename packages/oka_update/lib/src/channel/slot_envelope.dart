/// Publisher-side writer of S2 slot-update envelopes (`slot-update-*.json`
/// in the delivery directory the embedded [SlotRuntime] watches). This is
/// the channel seam of the S2 lane: the envelope rides the SAME signing
/// identity and canonical bytes as the air channel's pointer and revision
/// manifests (ADR-0037 G-AC5) — no second trust surface. Eligibility is
/// computed first (`planSlotSwap`); this file only delivers what was
/// proven applicable.
library;

import 'dart:io';

import 'channel_manifest.dart';
import 'signing.dart';

/// Schema version of the slot-update envelope (shared wire constant: the
/// publisher writes it, the embedded runtime parses it).
const int slotEnvelopeSchemaVersion = 1;

/// Writes one signed slot-update envelope into [directory] and returns
/// it. [artifact] names the staged part file the runtime must verify
/// (digest-checked) before flipping; paths are relative to [directory]
/// and must not escape it (the runtime refuses `..`).
///
/// Default file name: `slot-update-<family>-<revision>.json`.
Future<File> writeSlotUpdateEnvelope({
  required String directory,
  required String channel,
  required String family,
  required String revision,
  required ChannelSigner signer,
  UnitArtifact? artifact,
  int? issuedAtMs,
  String? fileName,
}) async {
  final envelope = await signer.sign({
    'schemaVersion': slotEnvelopeSchemaVersion,
    'channel': channel,
    'family': family,
    'revision': revision,
    if (artifact != null) 'artifact': artifact.toJson(),
    'issuedAtMs': issuedAtMs ?? DateTime.now().millisecondsSinceEpoch,
  });
  final dir = Directory(directory);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final name = fileName ?? 'slot-update-$family-$revision.json';
  final file = File('${dir.path}/$name');
  // A stale envelope of the same name must not silently survive next to
  // the new one — one slot update per name, latest wins.
  if (file.existsSync()) file.deleteSync();
  file.writeAsStringSync('${canonicalJson(envelope)}\n');
  return file;
}
