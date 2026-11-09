import 'dart:convert';
import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

/// Fake registry hooks: the generated slot registry's shape, without AOT.
class FakeFamily {
  FakeFamily({this.current = 'r1'});
  final List<String> loads = [];
  String current;
  late final SlotFamilyRuntime runtime = SlotFamilyRuntime(
    revisions: {'r1', 'r2'},
    load: (revision) async {
      loads.add(revision);
      current = revision;
    },
    currentRevision: () => current,
  );
}

Future<(ChannelSigner, SlotRuntime, FakeFamily, String)> harness({
  String? channel,
  String anchorOf = 'signer',
}) async {
  final signer = await ChannelSigner.generate();
  final other = anchorOf == 'signer' ? signer : await ChannelSigner.generate();
  final family = FakeFamily();
  final runtime = SlotRuntime(
    spec: SlotRuntimeSpec(
      families: {'feature': family.runtime},
      trustedPublicKeyHex: other.publicKeyHex,
      channel: channel,
    ),
  );
  final dir = await Directory.systemTemp.createTemp('slot-runtime-test.');
  return (signer, runtime, family, dir.path);
}

void main() {
  test('signed envelope applies: loads r2, flips, receipts slot-swap',
      () async {
    final (signer, runtime, family, dir) = await harness();
    await writeSlotUpdateEnvelope(
      directory: dir,
      channel: 'stable',
      family: 'feature',
      revision: 'r2',
      signer: signer,
    );
    final receipt =
        await runtime.applyEnvelopeFile('$dir/slot-update-feature-r2.json');
    expect(receipt.mode, 'slot-swap');
    expect(receipt.family, 'feature');
    expect(receipt.from, 'r1');
    expect(receipt.to, 'r2');
    expect(family.loads, ['r2']);
    expect(family.current, 'r2');
    // Receipt written next to the envelope; envelope archived as .processed.
    final receiptJson = jsonDecode(
        File('$dir/slot-update-feature-r2.json.receipt.json')
            .readAsStringSync()) as Map<String, Object?>;
    expect(receiptJson['mode'], 'slot-swap');
    expect(File('$dir/slot-update-feature-r2.json.processed').existsSync(),
        isTrue);
    expect(File('$dir/slot-update-feature-r2.json').existsSync(), isFalse);
    await Directory(dir).delete(recursive: true);
  });

  test('replay of the current revision receipts already-current, no load',
      () async {
    final (signer, runtime, family, dir) = await harness();
    await writeSlotUpdateEnvelope(
        directory: dir,
        channel: 'stable',
        family: 'feature',
        revision: 'r2',
        signer: signer);
    await runtime.applyEnvelopeFile('$dir/slot-update-feature-r2.json');
    await writeSlotUpdateEnvelope(
        directory: dir,
        channel: 'stable',
        family: 'feature',
        revision: 'r2',
        signer: signer);
    final receipt =
        await runtime.applyEnvelopeFile('$dir/slot-update-feature-r2.json');
    expect(receipt.mode, 'already-current');
    expect(family.loads, ['r2']);
    await Directory(dir).delete(recursive: true);
  });

  test('a different valid key refuses (pinned anchor)', () async {
    final (signer, runtime, family, dir) = await harness(anchorOf: 'other');
    await writeSlotUpdateEnvelope(
        directory: dir,
        channel: 'stable',
        family: 'feature',
        revision: 'r2',
        signer: signer);
    final receipt =
        await runtime.applyEnvelopeFile('$dir/slot-update-feature-r2.json');
    expect(receipt.mode, 'refused');
    expect(receipt.refusalCode, 'slot_envelope_signature_invalid');
    expect(family.loads, isEmpty);
    await Directory(dir).delete(recursive: true);
  });

  test('unknown family and unknown revision refuse by name', () async {
    final (signer, runtime, family, dir) = await harness();
    await writeSlotUpdateEnvelope(
        directory: dir,
        channel: 'stable',
        family: 'ghost',
        revision: 'r2',
        signer: signer,
        fileName: 'env-ghost.json');
    await writeSlotUpdateEnvelope(
        directory: dir,
        channel: 'stable',
        family: 'feature',
        revision: 'r9',
        signer: signer,
        fileName: 'env-r9.json');
    final ghost = await runtime.applyEnvelopeFile('$dir/env-ghost.json');
    expect(ghost.refusalCode, 'slot_family_unknown');
    final r9 = await runtime.applyEnvelopeFile('$dir/env-r9.json');
    expect(r9.refusalCode, 'slot_revision_unknown');
    expect(r9.refusalReason, contains('provisioned: r1, r2'));
    expect(family.loads, isEmpty);
    await Directory(dir).delete(recursive: true);
  });

  test('wrong channel refuses', () async {
    final (signer, runtime, family, dir) = await harness(channel: 'stable');
    await writeSlotUpdateEnvelope(
        directory: dir,
        channel: 'beta',
        family: 'feature',
        revision: 'r2',
        signer: signer,
        fileName: 'env-beta.json');
    final receipt = await runtime.applyEnvelopeFile('$dir/env-beta.json');
    expect(receipt.refusalCode, 'slot_channel_unknown');
    expect(family.loads, isEmpty);
    await Directory(dir).delete(recursive: true);
  });

  test('malformed envelope receipts slot_envelope_malformed', () async {
    final (_, runtime, _, dir) = await harness();
    File('$dir/broken.json').writeAsStringSync('{not json');
    final receipt = await runtime.applyEnvelopeFile('$dir/broken.json');
    expect(receipt.mode, 'refused');
    expect(receipt.refusalCode, 'slot_envelope_malformed');
    await Directory(dir).delete(recursive: true);
  });

  test('staged artifact is digest-verified before the flip', () async {
    final (signer, runtime, family, dir) = await harness();
    final part = File('$dir/parts/base_feature_r2.part.so');
    part.parent.createSync(recursive: true);
    part.writeAsStringSync('aot-part-bytes');
    final goodSha = sha256Hex(part.readAsBytesSync());

    // Mismatched digest: refused, no flip.
    await writeSlotUpdateEnvelope(
        directory: dir,
        channel: 'stable',
        family: 'feature',
        revision: 'r2',
        signer: signer,
        artifact: const UnitArtifact(
            file: 'parts/base_feature_r2.part.so',
            sha256: 'deadbeef',
            bytes: 14),
        fileName: 'env-bad-digest.json');
    final bad = await runtime.applyEnvelopeFile('$dir/env-bad-digest.json');
    expect(bad.refusalCode, 'slot_artifact_digest_mismatch');
    expect(family.loads, isEmpty);

    // Missing artifact: refused.
    await writeSlotUpdateEnvelope(
        directory: dir,
        channel: 'stable',
        family: 'feature',
        revision: 'r2',
        signer: signer,
        artifact: UnitArtifact(
            file: 'parts/gone.part.so', sha256: goodSha, bytes: 14),
        fileName: 'env-missing.json');
    final missing = await runtime.applyEnvelopeFile('$dir/env-missing.json');
    expect(missing.refusalCode, 'slot_artifact_missing');

    // Matching digest: applies (artifact check precedes already-current —
    // the process below boots at r1, so this is a real flip).
    await writeSlotUpdateEnvelope(
        directory: dir,
        channel: 'stable',
        family: 'feature',
        revision: 'r2',
        signer: signer,
        artifact: UnitArtifact(
            file: 'parts/base_feature_r2.part.so',
            sha256: goodSha,
            bytes: 14),
        fileName: 'env-good.json');
    final good = await runtime.applyEnvelopeFile('$dir/env-good.json');
    expect(good.mode, 'slot-swap');
    expect(family.loads, ['r2']);
    await Directory(dir).delete(recursive: true);
  });

  test('decision order: artifact integrity precedes already-current',
      () async {
    final (signer, _, _, dir) = await harness();
    final family = FakeFamily()..current = 'r2';
    final spec = SlotRuntimeSpec(
      families: {'feature': family.runtime},
      trustedPublicKeyHex: signer.publicKeyHex,
    );
    final decision = decideSlotUpdate(
      envelope: SlotUpdateEnvelope.parse(await signer.sign({
        'schemaVersion': slotEnvelopeSchemaVersion,
        'channel': 'stable',
        'family': 'feature',
        'revision': 'r2',
        'artifact': {'file': 'p.so', 'sha256': 'x', 'bytes': 1},
        'issuedAtMs': 1,
      })),
      signature: const SignatureVerdict(ok: true),
      spec: spec,
      currentRevision: 'r2',
      artifactExists: true,
      artifactDigest: 'different',
    );
    expect(decision.mode, 'refused');
    expect(decision.refusalCode, 'slot_artifact_digest_mismatch');
    await Directory(dir).delete(recursive: true);
  });

  test('watchDirectory processes envelopes until stopped', () async {
    final (signer, runtime, family, dir) = await harness();
    await writeSlotUpdateEnvelope(
        directory: dir,
        channel: 'stable',
        family: 'feature',
        revision: 'r2',
        signer: signer);
    final receipts = <SlotApplyReceipt>[];
    await runtime.watchDirectory(
      dir,
      pollInterval: const Duration(milliseconds: 20),
      maxPerCycle: 4,
      onReceipt: receipts.add,
      until: () => receipts.isNotEmpty,
    );
    expect(receipts.single.mode, 'slot-swap');
    expect(family.current, 'r2');
    await Directory(dir).delete(recursive: true);
  });
}
