// The oka_conformance README documents the suite's helpers with concrete
// examples — this test runs them so the documented behavior can't drift:
// the plan-shape assertions and the scripted offline transport exactly as
// shown in the docs. No real network, ever (an unexpected request throws).
import 'package:http/http.dart' as http;
import 'package:oka_conformance/oka_conformance.dart';
import 'package:test/test.dart';

void main() {
  group('README: expectPlanShape / expectPlanDescribes', () {
    test('the documented plan shape assertion passes and fails correctly',
        () {
      // A dry-run plan exactly as a conforming target produces it (the
      // oka_play target's plan is the model for this fixture).
      const plan = PublishPlan(
        target: 'publish-play',
        endpoint: 'Google Play Publisher API (androidpublisher/v3)',
        track: 'internal',
        artifactId: 'aab-path',
        artifactPath: 'build/aab/app-release.aab',
        metadata: {'packageName': 'dev.example.app'},
        credentials: [
          CredentialRef(target: 'play', kind: 'service-account-json'),
        ],
        dryRun: true,
      );

      // Subset metadata matches; the plan may carry more entries.
      expectPlanShape(
        plan,
        target: 'publish-play',
        endpoint: 'Google Play Publisher API (androidpublisher/v3)',
        track: 'internal',
        artifactId: 'aab-path',
        dryRun: true,
        metadata: const {'packageName': 'dev.example.app'},
      );

      // The plan renders as describable text (the agent-facing law).
      expectPlanDescribes(plan, [
        'target: publish-play (dry run — nothing was uploaded)',
        'artifact: aab-path → build/aab/app-release.aab',
        'credential: CredentialRef(play/service-account-json → [redacted])',
      ]);

      // A mismatch surfaces as a PlanShapeException naming the field.
      expect(
        () => expectPlanShape(plan, track: 'production'),
        throwsA(isA<PlanShapeException>().having(
          (final e) => e.mismatches.join(' '),
          'mismatches',
          contains('track: expected production, plan says internal'),
        )),
      );
    });
  });

  group('README: FakeHttpTransport (offline real-run tests)', () {
    test('the documented scripting example records and replays', () async {
      final transport = FakeHttpTransport()
        ..routeJsonAlways(url: '/edits', json: {'id': 'synthetic-edit-id'});

      // Any http.Client built on the transport records every request —
      // here a plain request, in real tests the target's upload client.
      final response = await transport.send(
        http.Request('POST', Uri.parse('https://api.example.test/edits')),
      );
      expect(response.statusCode, 200);
      expect(transport.requests, hasLength(1));
      expect(
        transport.requests.single.url.toString(),
        'https://api.example.test/edits',
      );
      transport.close();
    });

    test('unexpected requests throw (offline by construction)', () {
      final transport = FakeHttpTransport();
      expect(
        () => transport.send(
          http.Request('GET', Uri.parse('https://api.example.test/other')),
        ),
        throwsA(isA<StateError>().having(
          (final e) => e.message,
          'message',
          contains('unexpected HTTP request'),
        )),
      );
    });

    test('assertNoRequests proves the dry-run zero-HTTP law', () async {
      // Dry run: nothing sent, nothing recorded.
      FakeHttpTransport().assertNoRequests();
      // After a request, the assertion throws — keeping future refactors
      // of dry-run chains honest.
      final transport = FakeHttpTransport()
        ..routeJsonAlways(url: '/x', json: const <String, dynamic>{});
      await transport.send(
        http.Request('GET', Uri.parse('https://api.example.test/x')),
      );
      expect(transport.assertNoRequests, throwsStateError);
    });
  });
}
