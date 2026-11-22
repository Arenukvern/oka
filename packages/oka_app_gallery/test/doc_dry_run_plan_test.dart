// The dry-run plan output documented in the README is asserted here
// verbatim: if the rendering ever drifts, this test fails and the docs get
// updated in the same commit. Fully offline — the dry-run chain is
// [appgallery-stage-aab, publish-plan] and issues zero HTTP (see the
// conformance test for the canary-proof).
import 'dart:io';

import 'package:oka_app_gallery/oka_app_gallery.dart';
import 'package:oka_conformance/oka_conformance.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  // Constructed in one string (adjacent strings are not allowed inside
  // list literals by the house lints).
  const agcEndpoint =
      'AppGallery Connect Publishing API '
      '(https://connect-api.cloud.huawei.com)';

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_app_gallery_doc_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('the README dry-run plan block matches the real rendering', () async {
    // Same target as the README quickstart / example/oka_pipeline_example.
    const target = AppGalleryPublishTarget(
      release: AppGalleryReleaseConfig(appId: '110012345'),
    );
    final ctx = BuildContext(
      projectPath: tmp.path,
      buildDir: 'build',
      mode: BuildMode.release,
      config: OkaConfig.empty,
    );

    final state = PipelineState();
    final result = await Pipeline(
      target.compile(ctx),
    ).run(ctx, initialState: state);
    expect(result.ok, isTrue, reason: result.error);

    final plan = state[PublishPlanStep.plan.id]! as PublishPlan;
    final lines = plan.describeLines();

    // The exact block the README shows for `oka run publish-app-gallery` (the
    // step output indents each line by two spaces under the
    // "📋 Publish plan" header).
    expect(lines, <String>[
      'target: publish-app-gallery (dry run — nothing was uploaded)',
      'endpoint: $agcEndpoint',
      'track: beta',
      'artifact: aab-path → build/aab/app-release.aab',
      'metadata.appId: 110012345',
      'metadata.phasePercent: 100',
      'credential: CredentialRef(appgallery/agconnect-credentials → [redacted])',
    ]);

    // And the credential path never renders — law 3.
    expect(lines.join('\n'), isNot(contains('credentials/agconnect')));
  });

  test('the documented failure candidates render in policy order', () {
    // (a) env var set but the file is missing → the env candidate is
    // listed in the "Tried" list, followed by the well-known location.
    final withEnv = CredentialResolver(
      environment: {
        'OKA_APPGALLERY_AGCONNECT_CREDENTIALS': p.join(tmp.path, 'nope.json'),
      },
      home: p.join(tmp.path, 'home'),
    );
    try {
      withEnv.require(AppGalleryPublishTarget.agconnectCredentials);
      fail('expected CredentialResolutionException');
    } on CredentialResolutionException catch (e) {
      final message = e.toString();
      expect(message, contains('Tried (in order):'));
      expect(message, contains('env OKA_APPGALLERY_AGCONNECT_CREDENTIALS'));
      expect(
        message,
        contains('~/.oka/credentials/appgallery/agconnect-credentials'),
      );
      expect(message, contains('Fix:'));
    }

    // (b) empty env → only the well-known candidate was tried, and the
    // fix names the env var (never a value — a path).
    final emptyEnv = CredentialResolver(environment: const {}, home: tmp.path);
    try {
      emptyEnv.require(AppGalleryPublishTarget.agconnectCredentials);
      fail('expected CredentialResolutionException');
    } on CredentialResolutionException catch (e) {
      final message = e.toString();
      expect(
        message,
        contains('~/.oka/credentials/appgallery/agconnect-credentials'),
      );
      expect(message, contains('OKA_APPGALLERY_AGCONNECT_CREDENTIALS'));
      expect(message, contains('never a value'));
    }
  });
}
