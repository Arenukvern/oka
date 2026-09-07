// ADR-0014 P2 — the HuaweiPublishTarget against the shared publishing
// conformance suite (packages/oka_conformance, extracted at P1).
//
// The three laws: (1) dry-run without credentials compiles, validates, and
// plans without issuing any HTTP; (2) no stdin in any build path; (3) no
// secret values in PipelineState — only credential refs and booleans.
import 'dart:io';

import 'package:oka_conformance/oka_conformance.dart';
import 'package:oka_huawei/oka_huawei.dart';
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

const _target = HuaweiPublishTarget(
  release: HuaweiReleaseConfig(appId: '110012345'),
);

const _targetWithCredentialPath = HuaweiPublishTarget(
  release: HuaweiReleaseConfig(appId: '110012345'),
  credentialPath: 'credentials/agconnect-synthetic.json',
);

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_huawei_test_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('law 1 — dry-run without credentials, zero HTTP', () {
    test('the target passes the shared conformance suite', () async {
      await expectPublishConformance(
        _target,
        _ctx(tmp),
        sourcePaths: [p.absolute('lib/src')],
      );
    });

    test('the target passes with an explicit credential path (redacted)',
        () async {
      await expectPublishConformance(
        _targetWithCredentialPath,
        _ctx(tmp),
      );
    });

    test('compiles to stage → plan, and the plan never issues HTTP', () async {
      final ctx = _ctx(tmp);
      final chain = describeTarget(_target, ctx);
      expect(chain.isValid, isTrue, reason: chain.validationError);
      expect(
        chain.steps.map((final s) => s.name).toList(),
        ['huawei-stage-aab', 'publish-plan'],
        reason: 'the upload tail is substituted by the plan step (as code)',
      );

      final transport = FakeHttpTransport();
      final state = PipelineState();
      final result = await Pipeline(_target.compile(ctx))
          .run(ctx, initialState: state);
      expect(result.ok, isTrue, reason: result.error);
      transport.assertNoRequests();
    });

    test('the plan describes exactly what a real run would do', () async {
      final ctx = _ctx(tmp);
      final state = PipelineState();
      await Pipeline(_target.compile(ctx)).run(ctx, initialState: state);
      final plan = state[PublishPlanStep.plan.id]! as PublishPlan;

      expectPlanShape(
        plan,
        target: 'publish-huawei',
        artifactId: 'aab-path',
        track: HuaweiReleaseConfig.defaultTrack,
        dryRun: true,
        metadata: const {
          'appId': '110012345',
          'phasePercent': '100',
        },
        credentials: const [HuaweiPublishTarget.agconnectCredentials],
      );
      expectPlanDescribes(plan, [
        'endpoint: AppGallery Connect Publishing API',
        'artifact: aab-path',
        'credential: CredentialRef(huawei/agconnect-credentials → [redacted])',
        'dry run — nothing was uploaded',
      ]);
    });

    test('an explicit credential path renders only in redacted form',
        () async {
      final ctx = _ctx(tmp);
      final state = PipelineState();
      await Pipeline(_targetWithCredentialPath.compile(ctx))
          .run(ctx, initialState: state);
      final plan = state[PublishPlanStep.plan.id]! as PublishPlan;
      expectNoSecretMaterial(
        plan.describeLines().join('\n'),
        refs: plan.credentials,
        forbidden: ['agconnect-synthetic.json'],
        context: 'publish plan',
      );
    });

    test('a non-dry-run target compiles + validates but the audit never '
        'executes the upload tail', () async {
      const real = HuaweiPublishTarget(
        dryRun: false,
        release: HuaweiReleaseConfig(appId: '110012345'),
      );
      final chain = describeTarget(real, _ctx(tmp));
      expect(chain.isValid, isTrue, reason: chain.validationError);
      expect(
        chain.steps.map((final s) => s.name).toList(),
        ['huawei-stage-aab', 'agc-publish'],
      );
      final violations =
          await auditPublishConformance(real, _ctx(tmp));
      expect(violations, isEmpty);
    });
  });

  group('law 2 — no stdin in any build path', () {
    test('the package sources pass the scan', () async {
      final violations = await auditPublishConformance(
        _target,
        _ctx(tmp),
        sourcePaths: [p.absolute('lib/src')],
      );
      expect(violations.where((final v) => v.contains('law 2')), isEmpty);
    });
  });

  group('law 3 — no secret values in state', () {
    test('dry-run state holds only the staged path and the plan', () async {
      final ctx = _ctx(tmp);
      final state = PipelineState();
      await Pipeline(_target.compile(ctx)).run(ctx, initialState: state);
      expectStateRedacted(state);
      expect(state.snapshot['publish-plan'], isA<PublishPlan>());
      expect(state.snapshot['aab-path'], isA<String>());
    });
  });

  group('target shape', () {
    test('name is a lowercase identifier, never a reserved verb', () {
      expect(validateTargetName(_target.name), isNull);
      expect(_target.name, 'publish-huawei');
    });

    test('dryRun defaults to true — publish targets plan unless told to '
        'execute', () {
      expect(_target.dryRun, isTrue);
    });

    test('the credential ref derives the env var and well-known location',
        () {
      const ref = HuaweiPublishTarget.agconnectCredentials;
      expect(ref.envVarName, 'OKA_HUAWEI_AGCONNECT_CREDENTIALS');
      expect(ref.wellKnownPath,
          '~/.oka/credentials/huawei/agconnect-credentials');
    });
  });
}
