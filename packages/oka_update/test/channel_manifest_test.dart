import 'dart:convert';

import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

void main() {
  test('pointer round-trips through canonical JSON', () {
    const pointer = ChannelPointer(
        channel: 'stable',
        revision: 'abc123',
        policy: ChannelPolicy(maxChainBytes: 1024, maxChainRevisions: 4));
    final back =
        ChannelPointer.fromJson(jsonDecode(canonicalJson(pointer.toJson()))
            as Map<String, dynamic>);
    expect(back.channel, 'stable');
    expect(back.revision, 'abc123');
    expect(back.policy.maxChainBytes, 1024);
    expect(back.policy.maxChainRevisions, 4);
    expect(back.policy.requiresSignature, isFalse);
    expect(back.signedBy, isNull);
  });

  test('canonical JSON is key-order independent', () {
    final a = canonicalJson({
      'revision': 'r1',
      'parent': null,
      'units': {'b': 1, 'a': 2},
    });
    final b = canonicalJson({
      'parent': null,
      'revision': 'r1',
      'units': {'a': 2, 'b': 1},
    });
    expect(a, b);
  });

  test('revision node round-trips digests, fingerprints, artifacts', () {
    const delta = UnitArtifact(
        file: 'artifacts/feature-r2.delta.dill', sha256: 'deadbeef', bytes: 11);
    const snapshot =
        UnitArtifact(file: 'artifacts/r3.snapshot.zip', sha256: 'c0ffee', bytes: 99);
    const node = RevisionNode(
        revision: 'r2',
        parent: 'r1',
        baseline: 'r1',
        plan: RecordedPlan(
            patchable: true,
            changedUnits: ['feature'],
            coreChanged: false,
            reasons: []),
        coreFingerprint: 'core-2',
        units: {'feature': RevisionUnit(delta: delta)},
        libraries: {
          'feature': {'lib/units/feature.dart': 'aa11'},
        },
        fingerprints: {'feature': 'fp-1'},
        snapshot: snapshot);
    final back = RevisionNode.fromJson(
        jsonDecode(canonicalJson(node.toJson())) as Map<String, dynamic>);
    expect(back.revision, 'r2');
    expect(back.parent, 'r1');
    expect(back.plan!.changedUnits, ['feature']);
    expect(back.units['feature']!.delta!.bytes, 11);
    expect(back.libraries['feature']!['lib/units/feature.dart'], 'aa11');
    expect(back.fingerprints['feature'], 'fp-1');
    expect(back.snapshot!.artifactName, 'r3.snapshot.zip');
  });

  test('foreign schema versions refuse loudly', () {
    expect(
      () => ChannelPointer.fromJson(
          {'schemaVersion': 99, 'channel': 'x', 'revision': 'y'}),
      throwsFormatException,
    );
    expect(
      () => RevisionNode.fromJson({'schemaVersion': 0}),
      throwsFormatException,
    );
  });
}
