// The dry-run plan output documented in the README is asserted here
// verbatim: if the rendering ever drifts, this test fails and the docs get
// updated in the same commit. Fully offline — the dry-run chain is
// [huawei-stage-aab, publish-plan] and issues zero HTTP (see the
// conformance test for the canary-proof).
import 'dart:io';

import 'package:oka_android/oka_android.dart' show PipelineOverrides;
import 'package:oka_conformance/oka_conformance.dart';
import 'package:oka_huawei/oka_huawei.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  // Constructed in one string (adjacent strings are not allowed inside
  // list literals by the house lints).
  const agcEndpoint = 'AppGallery Connect Publishing API '
      '(https://connect-api.cloud.huawei.com)';

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_huawei_doc_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('the README dry-run plan block matches the real rendering', () async {
    // Same target as the README quickstart / example/oka_pipeline_example.
    const target = HuaweiPublishTarget(
      release: HuaweiReleaseConfig(appId: '110012345'),
    );
    final ctx = BuildContext(
      projectPath: tmp.path,
      buildDir: 'build',
      mode: BuildMode.release,
      config: OkaConfig.empty,
    );

    final state = PipelineState();
    final result =
        await Pipeline(target.compile(ctx)).run(ctx, initialState: state);
    expect(result.ok, isTrue, reason: result.error);

    final plan = state[PublishPlanStep.plan.id]! as PublishPlan;
    final lines = plan.describeLines();

    // The exact block the README shows for `oka run publish-huawei` (the
    // step output indents each line by two spaces under the
    // "📋 Publish plan" header).
    expect(lines, <String>[
      'target: publish-huawei (dry run — nothing was uploaded)',
      'endpoint: $agcEndpoint',
      'track: beta',
      'artifact: aab-path → build/aab/app-release.aab',
      'metadata.appId: 110012345',
      'metadata.phasePercent: 100',
      'credential: CredentialRef(huawei/agconnect-credentials → [redacted])',
    ]);

    // And the credential path never renders — law 3.
    expect(lines.join('\n'), isNot(contains('credentials/agconnect')));
  });

  test('the documented failure candidates render in policy order', () {
    // (a) env var set but the file is missing → the env candidate is
    // listed in the "Tried" list, followed by the well-known location.
    final withEnv = CredentialResolver(
      environment: {
        'OKA_HUAWEI_AGCONNECT_CREDENTIALS': p.join(tmp.path, 'nope.json'),
      },
      home: p.join(tmp.path, 'home'),
    );
    try {
      withEnv.require(HuaweiPublishTarget.agconnectCredentials);
      fail('expected CredentialResolutionException');
    } on CredentialResolutionException catch (e) {
      final message = e.toString();
      expect(message, contains('Tried (in order):'));
      expect(message, contains('env OKA_HUAWEI_AGCONNECT_CREDENTIALS'));
      expect(
        message,
        contains('~/.oka/credentials/huawei/agconnect-credentials'),
      );
      expect(message, contains('Fix:'));
    }

    // (b) empty env → only the well-known candidate was tried, and the
    // fix names the env var (never a value — a path).
    final emptyEnv = CredentialResolver(environment: const {}, home: tmp.path);
    try {
      emptyEnv.require(HuaweiPublishTarget.agconnectCredentials);
      fail('expected CredentialResolutionException');
    } on CredentialResolutionException catch (e) {
      final message = e.toString();
      expect(
        message,
        contains('~/.oka/credentials/huawei/agconnect-credentials'),
      );
      expect(message, contains('OKA_HUAWEI_AGCONNECT_CREDENTIALS'));
      expect(message, contains('never a value'));
    }
  });

  test('the documented GMS exclusion drops the Billing coordinate', () {
    // Same variant extraDeps as the README / example.
    const variant = HuaweiBuildVariant(
      overrides: PipelineOverrides(
        extraDeps: [
          'androidx.core:core-ktx:1.13.1',
          'com.android.billingclient:billing-ktx:7.0.0',
        ],
      ),
    );
    expect(variant.gmsFreeExtraDeps, ['androidx.core:core-ktx:1.13.1']);
    expect(
      variant.excludedGmsDeps,
      ['com.android.billingclient:billing-ktx:7.0.0'],
    );
  });
}
