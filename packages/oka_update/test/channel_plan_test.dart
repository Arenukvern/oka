import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

UnitArtifact _delta(String revision,
        {String unit = 'feature', int bytes = 10}) =>
    UnitArtifact(
        file: 'artifacts/$unit-$revision.delta.dill',
        sha256: 'sha-$unit-$revision',
        bytes: bytes);

RevisionNode _node(String revision, {
  String? parent,
  String baseline = 'store-1',
  bool patchable = true,
  Map<String, int> units = const {'feature': 10},
  UnitArtifact? snapshot,
}) =>
    RevisionNode(
        revision: revision,
        parent: parent,
        baseline: baseline,
        plan: parent == null
            ? null
            : RecordedPlan(
                patchable: patchable,
                changedUnits: units.keys.toList(),
                coreChanged: false,
                reasons: patchable ? [] : ['contract fingerprint changed']),
        coreFingerprint: 'core-$revision',
        units: {
          for (final e in units.entries)
            e.key: RevisionUnit(delta: _delta(revision, unit: e.key, bytes: e.value)),
        },
        libraries: {
          for (final e in units.keys)
            e: {'lib/units/$e.dart': 'sha-lib-$revision-$e'},
        },
        fingerprints: {for (final e in units.keys) e: 'fp-$e'},
        snapshot: snapshot);

ChannelPointer _pointer(
        {ChannelPolicy policy = const ChannelPolicy()}) =>
    ChannelPointer(channel: 'stable', revision: 'head', policy: policy);

void main() {
  test('up-to-date short-circuits', () {
    final head = _node('r2', parent: 'r1');
    final plan = planChain(
        pointer: _pointer(),
        headToBaseline: [head, _node('r1')],
        local: const LocalInstall(baseline: 'store-1', appliedRevision: 'r2'));
    expect(plan.mode, ChannelPlanMode.upToDate);
    expect(plan.ok, isTrue);
  });

  test('never-patched install chains from the baseline', () {
    final history = [
      _node('r3', parent: 'r2'),
      _node('r2', parent: 'r1'),
      _node('r1'),
    ];
    final plan = planChain(
        pointer: _pointer(),
        headToBaseline: history,
        local: const LocalInstall(baseline: 'r1'));
    expect(plan.mode, ChannelPlanMode.chain);
    // Applied oldest-first: r1 -> r2 -> r3.
    expect(
        plan.steps.map((s) => '${s.revision}/${s.unit}').toList(),
        ['r2/feature', 'r3/feature']);
    expect(plan.bytesTotal, 20);
  });

  test('patched install chains only its remaining segment', () {
    final history = [
      _node('r3', parent: 'r2'),
      _node('r2', parent: 'r1'),
      _node('r1'),
    ];
    final plan = planChain(
        pointer: _pointer(),
        headToBaseline: history,
        local: const LocalInstall(baseline: 'r1', appliedRevision: 'r2'));
    expect(plan.mode, ChannelPlanMode.chain);
    expect(plan.steps.single.revision, 'r3');
  });

  test('byte threshold resolves to the head snapshot', () {
    final history = [
      _node('r3', parent: 'r2', units: const {'feature': 700}),
      _node('r2', parent: 'r1', units: const {'feature': 700}),
      _node('r1'),
    ];
    final headWithSnapshot =
        _node('r3', parent: 'r2', units: const {'feature': 700},
            snapshot: _delta('r3.snapshot'));
    final plan = planChain(
        pointer: _pointer(
            policy: const ChannelPolicy(maxChainBytes: 1000)),
        headToBaseline: [headWithSnapshot, history[1], history[2]],
        local: const LocalInstall(baseline: 'r1'));
    expect(plan.mode, ChannelPlanMode.snapshot);
    expect(plan.snapshot, isNotNull);
    expect(plan.reasons.first, contains('maxChainBytes'));
  });

  test('threshold without a snapshot refuses naming the fix', () {
    final history = [
      _node('r3', parent: 'r2', units: const {'feature': 700}),
      _node('r2', parent: 'r1', units: const {'feature': 700}),
      _node('r1'),
    ];
    final plan = planChain(
        pointer: _pointer(
            policy: const ChannelPolicy(maxChainBytes: 1000)),
        headToBaseline: history,
        local: const LocalInstall(baseline: 'r1'));
    expect(plan.mode, ChannelPlanMode.refused);
    expect(plan.reasons.join(' '), contains('--snapshot'));
  });

  test('revision-count threshold and slot budget both fall back', () {
    final history = [
      for (var i = 9; i >= 1; i--)
        _node('r$i', parent: i > 1 ? 'r${i - 1}' : null),
    ];
    final pointer = _pointer();
    // Default policy allows exactly 8 patch revisions (r2..r9).
    final plan = planChain(
        pointer: pointer,
        headToBaseline: history,
        local: const LocalInstall(baseline: 'r1'));
    expect(plan.mode, ChannelPlanMode.chain);

    // The client slot budget is per-process (AOT slots) and can be tighter
    // than the channel policy; without a head snapshot it refuses, naming
    // both the budget and the missing snapshot.
    final plan2 = planChain(
        pointer: pointer,
        headToBaseline: history,
        local: const LocalInstall(baseline: 'r1'),
        slotBudget: 3);
    expect(plan2.mode, ChannelPlanMode.refused);
    expect(plan2.reasons.join(' '), contains('slot budget'));
  });

  test('store-boundary revisions cannot be chained across', () {
    final history = [
      _node('r4', parent: 'r3',
          snapshot: const UnitArtifact(
              file: 'artifacts/r4.snapshot.zip', sha256: 's', bytes: 1)),
      _node('r3', parent: 'r2', patchable: false),
      _node('r2', parent: 'r1'),
      _node('r1'),
    ];
    final plan = planChain(
        pointer: _pointer(
            policy: const ChannelPolicy(
                maxChainBytes: 1024 * 1024, maxChainRevisions: 32)),
        headToBaseline: history,
        local: const LocalInstall(baseline: 'r1'));
    expect(plan.mode, ChannelPlanMode.snapshot,
        reason: 'boundary forces the snapshot fallback');
    expect(plan.reasons.join(' '), contains('store boundar'));
  });

  test('unknown baseline or applied revision refuses with the store lane',
      () {
    final history = [
      _node('r2', parent: 'r1'),
      _node('r1'),
    ];
    final unknownBase = planChain(
        pointer: _pointer(),
        headToBaseline: history,
        local: const LocalInstall(baseline: 'other-store'));
    expect(unknownBase.mode, ChannelPlanMode.refused);
    expect(unknownBase.reasons.join(' '), contains('store lane'));

    final unknownApplied = planChain(
        pointer: _pointer(),
        headToBaseline: history,
        local:
            const LocalInstall(baseline: 'r1', appliedRevision: 'ghost'));
    expect(unknownApplied.mode, ChannelPlanMode.refused);
    expect(unknownApplied.reasons.join(' '), contains('ghost'));
  });
}
