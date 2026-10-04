import 'dart:convert';
import 'dart:io';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String appRoot;
  late String channelDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('oka-signing-test-');
    appRoot = '${tmp.path}/app';
    channelDir = '${tmp.path}/channel';
    Directory('$appRoot/lib/units').createSync(recursive: true);
    File('$appRoot/lib/core.dart').writeAsStringSync('int coreSeed() => 7;\n');
    File('$appRoot/lib/units/feature.dart')
        .writeAsStringSync('int featureValue() {\n  return 1;\n}\n');
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Future<DeltaArtifact> fakeCompile(DeltaRequest request) async {
    final file = File('${tmp.path}/${request.unit}-${request.revision}.dill');
    file.writeAsStringSync('delta:${request.unit}@${request.revision}');
    return DeltaArtifact(path: file.path, bytes: file.lengthSync());
  }

  Future<ShipReceipt> ship(String revision, {ChannelSigner? signer}) =>
      shipRevision(
        root: appRoot,
        units: const [
          PatchUnit(name: 'feature', libraries: ['lib/units/feature.dart']),
        ],
        channelDir: channelDir,
        revision: revision,
        compile: fakeCompile,
        signer: signer,
      );

  Map<String, dynamic> readJson(String path) =>
      (jsonDecode(File(path).readAsStringSync()) as Map)
          .cast<String, dynamic>();

  test('signed pointer and manifest verify under the embedded anchor',
      () async {
    final signer = await ChannelSigner.generate();
    await ship('base-rev', signer: signer);

    final pointerVerdict = await verifySignature(
        readJson('$channelDir/pointer.json'),
        trustedPublicKeyHex: signer.publicKeyHex);
    expect(pointerVerdict.ok, isTrue, reason: pointerVerdict.reason);

    final nodeVerdict = await verifySignature(
        readJson('$channelDir/manifests/base-rev.json'),
        trustedPublicKeyHex: signer.publicKeyHex);
    expect(nodeVerdict.ok, isTrue, reason: nodeVerdict.reason);
  });

  test('tampering breaks the signature; a foreign anchor refuses', () async {
    final signer = await ChannelSigner.generate();
    await ship('base-rev', signer: signer);
    final pointerJson = readJson('$channelDir/pointer.json');

    // Tamper: the pointer pins a different revision.
    final tampered = {...pointerJson, 'revision': 'evil'};
    final tamperVerdict = await verifySignature(tampered,
        trustedPublicKeyHex: signer.publicKeyHex);
    expect(tamperVerdict.ok, isFalse);
    expect(tamperVerdict.reason, contains('does not verify'));

    // Foreign anchor: a valid signature from a different key refuses.
    final stranger = await ChannelSigner.generate();
    final foreignVerdict = await verifySignature(pointerJson,
        trustedPublicKeyHex: stranger.publicKeyHex);
    expect(foreignVerdict.ok, isFalse);
    expect(foreignVerdict.reason, contains('untrusted key'));

    // Unsigned refuses.
    final unsigned = {...pointerJson}..remove('signedBy');
    expect((await verifySignature(unsigned,
                trustedPublicKeyHex: signer.publicKeyHex))
            .ok,
        isFalse);
  });

  test('trust anchor enforcement matrix through the client', () async {
    final signer = await ChannelSigner.generate();
    await ship('base-rev', signer: signer);
    File('$appRoot/lib/units/feature.dart')
        .writeAsStringSync('int featureValue() {\n  return 2;\n}\n');
    await ship('rev2', signer: signer);

    final source = FileChannelSource(channelDir);
    const client = UpdateClient();

    // Anchored install: verifies and chains.
    final okPlan = await client.check(
        source,
        const LocalInstall(
            baseline: 'base-rev', trustedPublicKeyHex: 'IGNORED'));
    // 'IGNORED' is not the real key — this must refuse.
    expect(okPlan.mode, ChannelPlanMode.refused);
    expect(okPlan.reasons.join(' '), contains('untrusted key'));

    // Hmm: LocalInstall is const with a placeholder — use the real key.
    final anchor = signer.publicKeyHex;
    final good = await client.check(
        source,
        LocalInstall(baseline: 'base-rev', trustedPublicKeyHex: anchor));
    expect(good.mode, ChannelPlanMode.chain);
    final receipt = await client.apply(
        source,
        LocalInstall(baseline: 'base-rev', trustedPublicKeyHex: anchor),
        stageDir: '${tmp.path}/stage');
    expect(receipt.ok, isTrue);

    // Unsigned channel + anchor present: refused.
    final unsignedPointer =
        readJson('$channelDir/pointer.json')..remove('signedBy');
    File('$channelDir/pointer.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(unsignedPointer));
    final unsignedPlan = await client.check(
        source,
        LocalInstall(baseline: 'base-rev', trustedPublicKeyHex: anchor));
    expect(unsignedPlan.mode, ChannelPlanMode.refused);
    expect(unsignedPlan.reasons.join(' '), contains('unsigned'));
  });

  test('key material round-trips through the seed', () async {
    final signer = await ChannelSigner.generate();
    final restored = await ChannelSigner.fromSeedHex(await signer.keySeedHex());
    expect(restored.publicKeyHex, signer.publicKeyHex);
    expect(
        () => ChannelSigner.fromSeedHex('abcd'),
        throwsArgumentError,
    );
  });
}
