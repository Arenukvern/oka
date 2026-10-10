import 'package:oka_supervisor/oka_supervisor.dart';
import 'package:resource_composition/resource_composition.dart';
import 'package:test/test.dart';

void main() {
  group('ComponentSpec revision hashing', () {
    test('is stable across instances with equal declarations', () {
      const a = ComponentSpec(
        id: 'api',
        providerName: 'leased',
        env: {'PORT': '8080'},
      );
      const b = ComponentSpec(
        id: 'api',
        providerName: 'leased',
        env: {'PORT': '8080'},
      );
      expect(a.revisionHash, b.revisionHash);
      expect(a.toCanonicalJson(), b.toCanonicalJson());
    });

    test('changes when the declaration changes', () {
      const base = ComponentSpec(id: 'api', providerName: 'leased');
      const other = ComponentSpec(id: 'api', providerName: 'other');
      expect(base.revisionHash, isNot(other.revisionHash));
      expect(
        base.revisionHash,
        isNot(
          const ComponentSpec(
            id: 'api',
            providerName: 'leased',
            policy: SupervisionPolicy(revision: 2),
          ).revisionHash,
        ),
      );
    });

    test('canonical json is key-sorted', () {
      const spec = ComponentSpec(id: 'x', providerName: 'p');
      expect(
        spec.toCanonicalJson().indexOf('"id"'),
        lessThan(spec.toCanonicalJson().indexOf('"provider"')),
      );
    });
  });

  group('DesiredState validation', () {
    test('unknown provider names fail before any side effect', () {
      const desired = DesiredState(
        specs: [ComponentSpec(id: 'api', providerName: 'no-such-provider')],
      );
      Object? caught;
      try {
        desired.composition((final name) => throw StateError(name));
        // ignore: avoid_catching_errors
      } on ArgumentError catch (error) {
        caught = error;
      }
      expect(caught, isA<ArgumentError>());
      expect('$caught', contains('no-such-provider'));
    });

    test('duplicate ids surface through the substrate validator', () {
      const desired = DesiredState(
        specs: [
          ComponentSpec(id: 'api', providerName: 'fake'),
          ComponentSpec(id: 'api', providerName: 'fake'),
        ],
      );
      final report = desired.validate((final name) => FakeProvider());
      expect(report.ok, isFalse);
      final codes = report.issues.map((final issue) => issue.code);
      expect(codes, contains('duplicateComponentId'));
    });

    test('valid state validates clean', () {
      const desired = DesiredState(
        specs: [
          ComponentSpec(id: 'db', providerName: 'fake', provides: ['db.port']),
          ComponentSpec(
            id: 'api',
            providerName: 'fake',
            dependsOn: ['db'],
            requires: ['db.port'],
          ),
        ],
      );
      final report = desired.validate((final name) => FakeProvider());
      expect(report.ok, isTrue);
    });
  });

  group('Trigger vocabulary', () {
    test('describes deterministically', () {
      expect(const NoTrigger().describe(), 'none');
      expect(
        const WatchTrigger(roots: ['lib'], extensions: ['dart']).describe(),
        'watch:lib [dart]',
      );
      expect(
        const IntervalTrigger(period: Duration(hours: 6)).describe(),
        'interval:21600s',
      );
    });
  });
}
