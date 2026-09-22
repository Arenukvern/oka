import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

final class _Provider implements CacheDiagnosticProvider {
  const _Provider(this.id, this.result, {this.fail = false});
  @override
  final String id;
  final CacheDiagnosticContribution result;
  final bool fail;
  @override
  Future<CacheDiagnosticContribution> inspect(
    CacheDiagnosticContext context,
  ) async {
    if (fail) throw StateError('provider unavailable');
    return result;
  }
}

void main() {
  final context = CacheDiagnosticContext(
    projects: [],
    environment: {},
    storage: const StorageReport(locations: [], totalBytes: 0),
    observedAt: DateTime.utc(2026, 9, 22),
  );
  const record = CacheDiagnosticRecord(
    id: 'custom:one',
    kind: 'custom-runtime',
    label: 'Custom runtime',
    platform: 'custom',
    metadata: {'version': 1},
  );
  test(
    'custom provider survives sibling failure and is namespaced in JSON',
    () async {
      final report = await CacheDiagnostics(
        providers: [
          const _Provider('broken', CacheDiagnosticContribution(), fail: true),
          const _Provider(
            'custom',
            CacheDiagnosticContribution(records: [record]),
          ),
        ],
      ).inspect(context);
      expect(report.records.single, record);
      expect(report.complete, isFalse);
      expect(report.issues.single.code, 'provider_failed');
      final json = report.toJson();
      expect(json['observed_at'], '2026-09-22T00:00:00.000Z');
      expect(((json['records']! as List).single as Map)['metadata'], {
        'custom': {'version': 1},
      });
      expect(report.selectKinds({'custom-runtime'}).records, [record]);
      expect(report.selectKinds({'session'}).records, isEmpty);
      expect(report.selectKinds({'session'}).issues, report.issues);
    },
  );
  test(
    'duplicate provider and record IDs cannot silently replace evidence',
    () async {
      final report = await CacheDiagnostics(
        providers: [
          const _Provider(
            'first',
            CacheDiagnosticContribution(records: [record]),
          ),
          const _Provider('first', CacheDiagnosticContribution()),
          const _Provider(
            'second',
            CacheDiagnosticContribution(records: [record]),
          ),
        ],
      ).inspect(context);
      expect(report.records, [record]);
      expect(report.providers[record.id], 'first');
      expect(report.issues.map((e) => e.code), [
        'duplicate_provider',
        'duplicate_record',
      ]);
    },
  );
  test(
    'non-JSON metadata becomes an issue without discarding valid siblings',
    () async {
      const bad = CacheDiagnosticRecord(
        id: 'bad',
        kind: 'custom-runtime',
        label: 'Bad',
        platform: 'custom',
        metadata: {'object': Object()},
      );
      final report = await CacheDiagnostics(
        providers: [
          const _Provider(
            'custom',
            CacheDiagnosticContribution(records: [bad, record]),
          ),
        ],
      ).inspect(context);
      expect(report.records, [record]);
      expect(report.issues.single.code, 'invalid_metadata');
    },
  );
}
