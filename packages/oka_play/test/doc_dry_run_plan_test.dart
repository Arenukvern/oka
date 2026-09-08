// The dry-run plan output documented in the README is asserted here
// verbatim: if the rendering ever drifts, this test fails and the docs get
// updated in the same commit. Fully offline — the dry-run chain is
// [stage-aab, publish-plan] and issues zero HTTP (see the conformance test
// for the canary-proof).
import 'dart:io';

import 'package:oka_conformance/oka_conformance.dart';
import 'package:oka_play/oka_play.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_play_doc_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('the README dry-run plan block matches the real rendering', () async {
    // Same target as the README quickstart / example/oka_pipeline_example.
    const target = PlayPublishTarget(packageName: 'dev.example.app');
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

    // The exact block the README shows for `oka run publish-play` (the
    // step output indents each line by two spaces under the
    // "📋 Publish plan" header).
    expect(lines, <String>[
      'target: publish-play (dry run — nothing was uploaded)',
      'endpoint: Google Play Publisher API (androidpublisher/v3)',
      'track: internal',
      'artifact: aab-path → build/aab/app-release.aab',
      'metadata.packageName: dev.example.app',
      'credential: CredentialRef(play/service-account-json → [redacted])',
    ]);

    // And the credential path never renders — law 3.
    expect(lines.join('\n'), isNot(contains('credentials/')));
  });

  test('the documented failure candidates render in policy order', () {
    // (a) env var set but the file is missing → the env candidate is
    // listed in the "Tried" list, followed by the well-known location.
    final withEnv = CredentialResolver(
      environment: {
        'OKA_PLAY_SERVICE_ACCOUNT_JSON': p.join(tmp.path, 'nope.json'),
      },
      home: p.join(tmp.path, 'home'),
    );
    try {
      withEnv.require(playServiceAccountRef());
      fail('expected CredentialResolutionException');
    } on CredentialResolutionException catch (e) {
      final message = e.toString();
      expect(message, contains('Tried (in order):'));
      expect(message, contains('env OKA_PLAY_SERVICE_ACCOUNT_JSON'));
      expect(
        message,
        contains('~/.oka/credentials/play/service-account-json'),
      );
      expect(message, contains('Fix:'));
    }

    // (b) empty env → only the well-known candidate was tried, and the
    // fix names the env var (never a value — a path).
    final emptyEnv = CredentialResolver(environment: const {}, home: tmp.path);
    try {
      emptyEnv.require(playServiceAccountRef());
      fail('expected CredentialResolutionException');
    } on CredentialResolutionException catch (e) {
      final message = e.toString();
      expect(
        message,
        contains('~/.oka/credentials/play/service-account-json'),
      );
      expect(message, contains('OKA_PLAY_SERVICE_ACCOUNT_JSON'));
      expect(message, contains('never a value'));
    }
  });
}
