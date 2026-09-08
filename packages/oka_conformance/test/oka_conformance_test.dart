// oka_conformance self-test — the helpers must fail loudly on violations
// and stay silent on conforming input, with no secret values echoed.
import 'package:oka_conformance/oka_conformance.dart';
import 'package:test/test.dart';

const _ref = CredentialRef(
  target: 'fixture',
  kind: 'service-account-json',
  explicitPath: 'credentials/fixture-sa.json',
);

void main() {
  group('expectNoSecretMaterial', () {
    test('redacted output passes', () {
      expectNoSecretMaterial(
        'credential: $_ref\ntrack: internal',
        refs: [_ref],
      );
    });

    test('an explicit credential path is a finding', () async {
      await expectLater(
        () => expectNoSecretMaterial(
          'resolved to credentials/fixture-sa.json',
          refs: [_ref],
        ),
        throwsA(
          isA<SecretMaterialException>().having(
            (final e) => e.toString(),
            'message',
            allOf(contains('credentials/fixture-sa.json'), contains('redacted')),
          ),
        ),
      );
    });

    test('forbidden material is named without echoing the value', () async {
      await expectLater(
        () => expectNoSecretMaterial(
          'header: synthetic-value-not-a-secret',
          forbidden: ['synthetic-value-not-a-secret'],
        ),
        throwsA(
          isA<SecretMaterialException>().having(
            (final e) => e.toString(),
            'message',
            allOf(
              contains('forbidden material'),
              contains('"synthetic-value-not-a-secret"'),
              contains('never the value'),
            ),
          ),
        ),
      );
    });
  });

  group('expectStateRedacted', () {
    test('a clean state passes', () {
      final state = PipelineState()..['aab-path'] = '/build/app.aab';
      expectStateRedacted(state, refs: [_ref]);
    });

    test('a non-allowed value type fails', () async {
      final state = PipelineState()
        ..['extra'] = <String, String>{'k': 'v'};
      await expectLater(
        () => expectStateRedacted(state),
        throwsA(isA<SecretMaterialException>()),
      );
    });
  });

  group('expectPlanShape', () {
    late PublishPlan plan;
    setUp(() {
      plan = const PublishPlan(
        target: 'publish-fixture',
        endpoint: 'Fake Publisher API v1',
        track: 'internal',
        artifactId: 'aab-path',
        artifactPath: '/build/app-release.aab',
        metadata: {'versionName': '1.2.3'},
        credentials: [_ref],
        dryRun: true,
      );
    });

    test('a matching plan passes', () {
      expectPlanShape(
        plan,
        target: 'publish-fixture',
        endpoint: 'Fake Publisher API v1',
        track: 'internal',
        artifactId: 'aab-path',
        dryRun: true,
        metadata: {'versionName': '1.2.3'},
        credentials: [_ref],
      );
      expectPlanDescribes(plan, ['track: internal', 'artifact: aab-path']);
    });

    test('a mismatched plan fails naming the field', () async {
      await expectLater(
        () => expectPlanShape(plan, track: 'production'),
        throwsA(
          isA<PlanShapeException>().having(
            (final e) => e.toString(),
            'message',
            contains('track: expected production'),
          ),
        ),
      );
    });

    test('exactMetadata catches extra keys', () async {
      await expectLater(
        () => expectPlanShape(plan, exactMetadata: true),
        throwsA(
          isA<PlanShapeException>().having(
            (final e) => e.toString(),
            'message',
            contains('unexpected key "versionName"'),
          ),
        ),
      );
    });
  });

  group('FakeHttpTransport', () {
    test('routes scripted requests and records them in order', () async {
      final transport = FakeHttpTransport()
        ..routeJsonAlways(
          url: 'example.test/api',
          json: {'ok': true},
        );
      final response = await transport.post(
        Uri.parse('https://example.test/api/edits'),
        body: '{"a":1}',
      );
      expect(response.statusCode, 200);
      expect(transport.requests.single.url.toString(),
          'https://example.test/api/edits');
      expect(transport.requests.single.bodyJson, {'a': 1});
    });

    test('unrouted requests throw (offline by construction)', () {
      final transport = FakeHttpTransport();
      expect(
        () => transport.get(Uri.parse('https://example.test/other')),
        throwsA(isA<StateError>()),
      );
    });

    test('assertNoRequests proves the zero-HTTP law', () {
      final empty = FakeHttpTransport();
      empty.assertNoRequests(); // passes — nothing recorded

      final used = FakeHttpTransport()
        ..requests.add(
          RecordedRequest(
            method: 'GET',
            url: Uri.parse('https://x.test'),
            headers: const {},
            body: const [],
          ),
        );
      expect(used.requestCount, 1);
      expect(
        used.assertNoRequests,
        throwsA(isA<StateError>().having(
          (final e) => e.toString(),
          'message',
          allOf(contains('expected zero HTTP requests'), contains('saw 1')),
        )),
      );
    });
  });
}
