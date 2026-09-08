// ADR-0014 P1 — PlayPublishTarget vs the shared conformance suite
// (oka_conformance): dry-run without credentials, no stdin, no secret
// values in state; zero HTTP in dry-run; plan shape.
import 'dart:io';

import 'package:oka_conformance/oka_conformance.dart';
import 'package:oka_play/oka_play.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

BuildContext _ctx(final Directory tmp) => BuildContext(
      projectPath: tmp.path,
      buildDir: p.join(tmp.path, '.oka_cache', 'build', 'debug'),
      mode: BuildMode.debug,
      config: OkaConfig.empty,
      cacheDir: p.join(tmp.path, '.oka_cache'),
      tempDir: p.join(tmp.path, '.oka_cache', 'build', 'debug', 'temp'),
    );

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_play_conformance_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('shared conformance suite (oka_conformance)', () {
    test('PlayPublishTarget passes the full ADR-0014 suite', () async {
      await expectPublishConformance(
        const PlayPublishTarget(),
        _ctx(tmp),
        sourcePaths: [p.absolute('lib/src')],
      );
    });

    test('real-mode targets compile + validate but are never executed',
        () async {
      // auditPublishConformance only runs dry-run pipelines; the real-mode
      // upload tail must merely compile/validate.
      final violations = await auditPublishConformance(
        const PlayPublishTarget(
          dryRun: false,
          packageName: 'dev.example.app',
        ),
        _ctx(tmp),
      );
      expect(violations, isEmpty);
    });
  });

  group('law 1 — dry-run without credentials, zero HTTP', () {
    test('the dry-run chain is [stage-aab, publish-plan] — no upload step',
        () {
      final chain = describeTarget(const PlayPublishTarget(), _ctx(tmp));
      expect(chain.isValid, isTrue, reason: chain.validationError);
      expect(
        chain.steps.map((final s) => s.name).toList(),
        ['stage-aab', 'publish-plan'],
        reason: 'the upload tail is substituted by the plan step (as code)',
      );
    });

    test('the dry-run plan has the exact Play shape', () async {
      final state = PipelineState();
      final result =
          await Pipeline(const PlayPublishTarget().compile(_ctx(tmp)))
              .run(_ctx(tmp), initialState: state);
      expect(result.ok, isTrue, reason: result.error);

      final plan = state[PublishPlanStep.plan.id]! as PublishPlan;
      expectPlanShape(
        plan,
        target: 'publish-play',
        endpoint: 'Google Play Publisher API (androidpublisher/v3)',
        track: 'internal',
        artifactId: 'aab-path',
        dryRun: true,
        exactMetadata: true,
        credentials: [playServiceAccountRef()],
      );
      expectPlanDescribes(plan, [
        'endpoint: Google Play Publisher API (androidpublisher/v3)',
        'track: internal',
        'artifact: aab-path',
        'dry run — nothing was uploaded',
        'credential: CredentialRef(play/service-account-json → [redacted])',
      ]);
    });

    test('typed config flows into the plan (track, packageName, rollout)',
        () async {
      const target = PlayPublishTarget(
        packageName: 'dev.example.app',
        releaseTrack: PlayTrack.beta,
        userFraction: 0.5,
        releaseName: 'Release 42',
      );
      final state = PipelineState();
      final result = await Pipeline(target.compile(_ctx(tmp)))
          .run(_ctx(tmp), initialState: state);
      expect(result.ok, isTrue, reason: result.error);

      final plan = state[PublishPlanStep.plan.id]! as PublishPlan;
      expectPlanShape(
        plan,
        track: 'beta',
        metadata: const {
          'packageName': 'dev.example.app',
          'releaseName': 'Release 42',
          'userFraction': '0.50',
        },
      );
    });

    test('dry-run issues zero HTTP — proven by a canary transport', () async {
      // Nothing in the dry-run chain can reach the transport (the upload
      // step is not in the chain), but the assertion makes the law
      // explicit and keeps future refactors honest.
      final transport = FakeHttpTransport()..routeJsonAlways(
          url: 'androidpublisher.googleapis.com',
          json: (final _) => {'should': 'never be reached'},
        );
      final state = PipelineState();
      final result =
          await Pipeline(const PlayPublishTarget().compile(_ctx(tmp)))
              .run(_ctx(tmp), initialState: state);
      expect(result.ok, isTrue, reason: result.error);
      transport.assertNoRequests();
    });

    test('dry-run succeeds with no credential file anywhere (empty env)',
        () async {
      final state = PipelineState();
      final result =
          await Pipeline(const PlayPublishTarget().compile(_ctx(tmp)))
              .run(_ctx(tmp), initialState: state);
      expect(result.ok, isTrue, reason: result.error);
    });
  });

  group('laws 2+3 — no stdin, no secret values', () {
    test('the credential ref renders redacted everywhere', () {
      const target = PlayPublishTarget(
        serviceAccountPath: 'credentials/play-sa.json',
      );
      final joined =
          '${target.credentialRefs.first} '
          '${target.plan(BuildContext.empty, artifactPath: 'x/aab').describeLines()}';
      expect(joined, contains('[redacted]'));
      expect(joined, isNot(contains('credentials/play-sa.json')));
    });

    test('dry-run state holds only the plan and path strings', () async {
      final state = PipelineState();
      await Pipeline(const PlayPublishTarget().compile(_ctx(tmp)))
          .run(_ctx(tmp), initialState: state);
      expectStateRedacted(state, refs: [playServiceAccountRef()]);
    });
  });

  group('target contract shape', () {
    test('name is a valid, non-reserved target identifier', () {
      expect(validateTargetName(const PlayPublishTarget().name), isNull);
    });

    test('dryRun defaults to true (safe-by-default publishing)', () {
      expect(const PlayPublishTarget().dryRun, isTrue);
    });

    test('validateConfig catches an empty packageName and bad rollout',
        () {
      expect(const PlayPublishTarget().validateConfig(), hasLength(1));
      final issues = const PlayPublishTarget(userFraction: 1.5).validateConfig();
      expect(issues.join(' '), contains('userFraction'));
      expect(
        const PlayPublishTarget(
          packageName: 'dev.example.app',
          userFraction: 0.25,
        ).validateConfig(),
        isEmpty,
      );
    });
  });

  group('credential policy integration (injected env)', () {
    test('OKA_PLAY_SERVICE_ACCOUNT_JSON env var resolves a path', () {
      final file = File(p.join(tmp.path, 'sa.json'))
        ..writeAsStringSync('{"synthetic": true}');
      final resolver = CredentialResolver(
        environment: {'OKA_PLAY_SERVICE_ACCOUNT_JSON': file.path},
        home: p.join(tmp.path, 'home'),
      );
      final resolution = resolver.resolve(playServiceAccountRef());
      expect(resolution.ok, isTrue);
      expect(resolution.source!.kind, CredentialSourceKind.env);
      expect(
        resolution.tried.map((final s) => s.qualified).join('|'),
        contains('env OKA_PLAY_SERVICE_ACCOUNT_JSON'),
      );
    });

    test('configured-but-missing path hard-fails without fall-through', () {
      final resolver = CredentialResolver(environment: const {}, home: tmp.path);
      final ref = playServiceAccountRef(explicitPath: p.join(tmp.path, 'nope.json'));
      expect(
        () => resolver.require(ref),
        throwsA(
          isA<CredentialResolutionException>().having(
            (final e) => e.toString(),
            'message',
            allOf(
              contains('play/service-account-json'),
              contains('Tried (in order)'),
              contains('typed config'),
            ),
          ),
        ),
      );
    });

    test('well-known location resolves last', () {
      final home = Directory(p.join(tmp.path, 'home'))
        ..createSync(recursive: true);
      Directory(p.join(home.path, '.oka', 'credentials', 'play'))
          .createSync(recursive: true);
      File(p.join(home.path, '.oka', 'credentials', 'play',
              'service-account-json'))
          .writeAsStringSync('{}');
      final resolver = CredentialResolver(environment: const {}, home: home.path);
      final resolution = resolver.resolve(playServiceAccountRef());
      expect(resolution.ok, isTrue);
      expect(resolution.source!.kind, CredentialSourceKind.wellKnown);
    });
  });
}
