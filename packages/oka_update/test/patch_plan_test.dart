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
  test('body-only unit change is patchable and names the unit', () {
    final base = manifest('rev-b', units: {
      'alpha': (sha: 'aaa', fingerprint: 'fp-a'),
      'beta': (sha: 'bbb', fingerprint: 'fp-b'),
    });
    final next = manifest('rev-c', units: {
      'alpha': (sha: 'aaa2', fingerprint: 'fp-a'),
      'beta': (sha: 'bbb', fingerprint: 'fp-b'),
    });
    final plan = planRevisions(base, next);
    expect(plan.patchable, isTrue);
    expect(plan.changedUnits, ['alpha']);
    expect(plan.coreChanged, isFalse);
    expect(plan.alternative, isNull);
  });

  test('contract fingerprint change refuses with explicit alternative', () {
    final base = manifest('rev-c', units: {
      'beta': (sha: 'bbb', fingerprint: 'fp-b'),
    });
    final next = manifest('rev-bad', units: {
      'beta': (sha: 'bbb2', fingerprint: 'fp-b2'),
    });
    final plan = planRevisions(base, next);
    expect(plan.patchable, isFalse);
    expect(plan.changedUnits, isEmpty);
    expect(plan.reasons.single, contains('beta'));
    expect(plan.alternative, 'full release via store lane');
  });

  test('added or removed units are structural changes', () {
    final base = manifest('r1', units: {
      'alpha': (sha: 'a', fingerprint: 'fa'),
    });
    final added = manifest('r2', units: {
      'alpha': (sha: 'a', fingerprint: 'fa'),
      'gamma': (sha: 'g', fingerprint: 'fg'),
    });
    expect(planRevisions(base, added).patchable, isFalse);
    expect(planRevisions(added, base).patchable, isFalse);
  });

  test('core fingerprint movement is reported for transfer accounting', () {
    final base = manifest('r1', units: {
      'alpha': (sha: 'a', fingerprint: 'fa'),
    });
    final next = manifest('r2', units: {
      'alpha': (sha: 'a2', fingerprint: 'fa'),
    }, coreFingerprint: 'core-2');
    final plan = planRevisions(base, next);
    expect(plan.patchable, isTrue);
    expect(plan.coreChanged, isTrue);
  });
}
