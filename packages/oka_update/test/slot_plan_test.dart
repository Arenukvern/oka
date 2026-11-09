import 'package:oka_update/oka_update.dart';
import 'package:test/test.dart';

Map<String, dynamic> manifest(
  String revision, {
  required Map<String, ({String sha, String fingerprint})> units,
  String coreFingerprint = 'core-1',
}) =>
    {
      'schemaVersion': 1,
      'revision': revision,
      'coreFingerprint': coreFingerprint,
      'units': {
        for (final e in units.entries)
          e.key: {
            'libraries': {
              'lib/units/${e.key}.dart': {'sha256': e.value.sha},
            },
            'contractFingerprint': e.value.fingerprint,
          },
      },
    };

void main() {
  test('body-only change with a provisioned target slot is eligible', () {
    final base = manifest('rev-b',
        units: {'feature': (sha: 'aaa', fingerprint: 'fp-a')});
    final next = manifest('rev-c',
        units: {'feature': (sha: 'bbb', fingerprint: 'fp-a')});
    final plan = planSlotSwap(
      base,
      next,
      unitTargets: {'feature': 'r2'},
      provisionedSlots: {
        'feature': {'r1', 'r2'},
      },
    );
    expect(plan.patch.patchable, isTrue);
    expect(plan.slotEligible, isTrue);
    expect(plan.unitSlots, {'feature': 'feature_r2'});
    expect(plan.reasons, isEmpty);
    expect(plan.alternative, isNull);
  });

  test('unprovisioned target revision refuses by name', () {
    final base = manifest('rev-b',
        units: {'feature': (sha: 'aaa', fingerprint: 'fp-a')});
    final next = manifest('rev-c',
        units: {'feature': (sha: 'bbb', fingerprint: 'fp-a')});
    final plan = planSlotSwap(
      base,
      next,
      unitTargets: {'feature': 'r3'},
      provisionedSlots: {
        'feature': {'r1', 'r2'},
      },
    );
    expect(plan.slotEligible, isFalse);
    expect(plan.unitSlots, isEmpty);
    expect(plan.reasons.single, contains('`r3` is not provisioned'));
    expect(plan.alternative, 'full release via store lane');
  });

  test('unit with no provisioned slot registry refuses', () {
    final base = manifest('rev-b',
        units: {'beta': (sha: 'aaa', fingerprint: 'fp-b')});
    final next = manifest('rev-c',
        units: {'beta': (sha: 'bbb', fingerprint: 'fp-b')});
    final plan = planSlotSwap(
      base,
      next,
      unitTargets: {'beta': 'r1'},
      provisionedSlots: const {},
    );
    expect(plan.slotEligible, isFalse);
    expect(plan.reasons.single, contains('no provisioned slot registry'));
  });

  test('contract fingerprint change carries the patch refusal', () {
    final base = manifest('rev-b',
        units: {'feature': (sha: 'aaa', fingerprint: 'fp-a')});
    final next = manifest('rev-c',
        units: {'feature': (sha: 'bbb', fingerprint: 'fp-b')});
    final plan = planSlotSwap(
      base,
      next,
      unitTargets: {'feature': 'r2'},
      provisionedSlots: {
        'feature': {'r1', 'r2'},
      },
    );
    expect(plan.patch.patchable, isFalse);
    expect(plan.slotEligible, isFalse);
    expect(plan.reasons.single, contains('contract fingerprint changed'));
  });

  test('missing target declaration refuses', () {
    final base = manifest('rev-b',
        units: {'feature': (sha: 'aaa', fingerprint: 'fp-a')});
    final next = manifest('rev-c',
        units: {'feature': (sha: 'bbb', fingerprint: 'fp-a')});
    final plan = planSlotSwap(
      base,
      next,
      unitTargets: const {},
      provisionedSlots: {
        'feature': {'r1', 'r2'},
      },
    );
    expect(plan.slotEligible, isFalse);
    expect(plan.reasons.single, contains('names no target revision slot'));
  });

  test('slot budget exceeded refuses', () {
    final base = manifest('rev-b',
        units: {'feature': (sha: 'aaa', fingerprint: 'fp-a')});
    final next = manifest('rev-c',
        units: {'feature': (sha: 'bbb', fingerprint: 'fp-a')});
    final plan = planSlotSwap(
      base,
      next,
      unitTargets: {'feature': 'r9'},
      provisionedSlots: {
        'feature': {'r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7', 'r8', 'r9'},
      },
    );
    expect(plan.slotEligible, isFalse);
    expect(plan.reasons.single, contains('slot budget'));
  });

  test('toJson carries the composed verdict and explicit alternative', () {
    final base = manifest('rev-b',
        units: {'feature': (sha: 'aaa', fingerprint: 'fp-a')});
    final next = manifest('rev-c',
        units: {'feature': (sha: 'bbb', fingerprint: 'fp-a')});
    final json = planSlotSwap(
      base,
      next,
      unitTargets: {'feature': 'r2'},
      provisionedSlots: {
        'feature': {'r1', 'r2'},
      },
    )
        .toJson();
    expect(json['slotEligible'], isTrue);
    expect(json['unitSlots'], {'feature': 'feature_r2'});
    expect(json['alternative'], isNull);
  });
}
