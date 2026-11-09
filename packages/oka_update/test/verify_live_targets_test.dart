import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

class _VerifyFake implements LivePatchTarget {
  _VerifyFake(this.id, {required this.values});

  @override
  final String id;

  @override
  final String kind = 'fake';

  final Map<String, String> values;

  @override
  Future<void> connect() async {}

  @override
  Future<ApplyOutcome> apply({
    required String unit,
    required String deltaPath,
    required int deltaBytes,
  }) async =>
      const ApplyOutcome(ok: false, mode: 'n/a', error: 'verify only');

  @override
  Future<ApplyOutcome> syncAsset({
    required String assetKey,
    required List<int> bytes,
    required String flutterAssetsDir,
    bool shader = false,
  }) async =>
      const ApplyOutcome(ok: false, mode: 'n/a', error: 'verify only');

  @override
  Future<String> evaluate(ProbeSpec probe) async =>
      values[probe.expression] ?? 'missing';

  @override
  Future<void> close() async {}
}

void main() {
  test('verifyLiveTargets rejects wrong numeric tick (999 vs expect 0)', () async {
    const spec = LivePatchSpec(
      revision: 'neg-tick',
      unit: 'gate',
      patches: [],
      targets: [TargetSpec(kind: 'fake', id: 'app')],
      probes: [
        ProbeSpec(expression: 'devGateSessionTick()', expect: '0'),
      ],
    );
    final receipt = await verifyLiveTargets(
      spec,
      root: '.',
      targetOverrides: {
        'app': _VerifyFake('app', values: {'devGateSessionTick()': '999'}),
      },
    );
    expect(receipt.ok, isFalse);
    final probe = receipt.targets.single.probes.single;
    expect(probe.ok, isFalse);
    expect(probe.after, '999');
    expect(probe.error, contains('expected'));
  });

  test('verifyLiveTargets rejects wrong fingerprint', () async {
    const spec = LivePatchSpec(
      revision: 'neg-fp',
      unit: 'gate',
      patches: [],
      targets: [TargetSpec(kind: 'fake', id: 'app')],
      probes: [
        ProbeSpec(expression: 'helloAssetFingerprint()', expect: '12345'),
      ],
    );
    final receipt = await verifyLiveTargets(
      spec,
      root: '.',
      targetOverrides: {
        'app': _VerifyFake('app', values: {'helloAssetFingerprint()': '999'}),
      },
    );
    expect(receipt.ok, isFalse);
    expect(receipt.targets.single.probes.single.ok, isFalse);
  });

  test('verifyLiveTargets accepts matching numeric observations', () async {
    const spec = LivePatchSpec(
      revision: 'pos',
      unit: 'gate',
      patches: [],
      targets: [TargetSpec(kind: 'fake', id: 'app')],
      probes: [
        ProbeSpec(expression: 'devGateSessionTick()', expect: '1'),
        ProbeSpec(expression: 'helloAssetFingerprint()', expect: '42'),
      ],
    );
    final receipt = await verifyLiveTargets(
      spec,
      root: '.',
      targetOverrides: {
        'app': _VerifyFake('app', values: {
          'devGateSessionTick()': '1',
          'helloAssetFingerprint()': '42',
        }),
      },
    );
    expect(receipt.ok, isTrue);
    expect(
      receipt.targets.single.probes.map((p) => p.ok),
      everyElement(isTrue),
    );
  });
}
