// ADR-0014 P2 — HuaweiStageAabStep artifact resolution + typed
// `artifactPath` override (publish-adoption gap fix).
//
// The oka AAB build writes the signed bundle to
// `<buildDir>/aab/app-<mode>.aab` (`packageAndSignAab` in oka_android) —
// the stage fallback must name exactly that path, so a real
// `oka run publish-huawei --release --aab` after `oka build aab --release`
// stages the bundle that actually exists.
import 'dart:io';

import 'package:oka_core/oka_core.dart';
import 'package:oka_huawei/oka_huawei.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

BuildContext _ctx(final Directory tmp, {final BuildMode mode = BuildMode.debug}) =>
    BuildContext(
      projectPath: tmp.path,
      buildDir: p.join(tmp.path, '.oka_cache', 'build', '${mode.name}-aab'),
      mode: mode,
      config: OkaConfig.empty,
      cacheDir: p.join(tmp.path, '.oka_cache'),
    );

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('oka_huawei_stage_');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group(
    'HuaweiStageAabStep fallback resolves the real oka AAB output path',
    () {
      test('fallback is <buildDir>/aab/app-<mode>.aab', () async {
        final ctx = _ctx(tmp, mode: BuildMode.release);
        final state = PipelineState();
        final result = await HuaweiStageAabStep().run(ctx, state);

        expect(result.ok, isTrue, reason: result.error);
        expect(
          state[HuaweiStageAabStep.aabPath.id],
          p.join(ctx.buildDir, 'aab', 'app-release.aab'),
        );
        expect(
          state[HuaweiStageAabStep.aabPath.id],
          HuaweiStageAabStep.defaultAabPath(ctx),
        );
      });

      test('fallback honours the build mode', () async {
        final ctx = _ctx(tmp);
        final state = PipelineState();
        await HuaweiStageAabStep().run(ctx, state);

        expect(
          state[HuaweiStageAabStep.aabPath.id],
          p.join(ctx.buildDir, 'aab', 'app-debug.aab'),
        );
      });

      test('the Android build artifact slot (apk_path) wins over the fallback',
          () async {
        final ctx = _ctx(tmp);
        final staged = p.join(tmp.path, 'built', 'app-release.aab');
        final state = PipelineState()..['apk_path'] = staged;
        await HuaweiStageAabStep().run(ctx, state);

        expect(state[HuaweiStageAabStep.aabPath.id], staged);
      });

      test('an upstream aab-path wins over the apk_path slot', () async {
        final ctx = _ctx(tmp);
        final state = PipelineState()
          ..[HuaweiStageAabStep.aabPath.id] = p.join(tmp.path, 'upstream.aab')
          ..['apk_path'] = p.join(tmp.path, 'built', 'app-release.aab');
        await HuaweiStageAabStep().run(ctx, state);

        expect(state[HuaweiStageAabStep.aabPath.id], p.join(tmp.path, 'upstream.aab'));
      });
    },
  );

  group('typed artifactPath override (ADR-0014 typed config)', () {
    test('the override wins over state and the default layout', () async {
      final ctx = _ctx(tmp);
      final override = p.join(tmp.path, 'custom', 'bundle.aab');
      final state = PipelineState()..['apk_path'] = p.join(tmp.path, 'b.aab');
      await HuaweiStageAabStep(artifactPath: override).run(ctx, state);

      expect(state[HuaweiStageAabStep.aabPath.id], override);
    });

    test('the target threads the override into the dry-run plan', () async {
      const target = HuaweiPublishTarget(
        artifactPath: '/custom/path/app.aab',
      );
      final ctx = _ctx(tmp);
      final state = PipelineState();
      final result =
          await Pipeline(target.compile(ctx)).run(ctx, initialState: state);

      expect(result.ok, isTrue, reason: result.error);
      final plan = state[PublishPlanStep.plan.id]! as PublishPlan;
      expect(plan.artifactPath, '/custom/path/app.aab');
    });
  });

  group('real-run mismatch names the expected path', () {
    test('a missing bundle fails naming the staged (expected) path',
        () async {
      final ctx = _ctx(tmp, mode: BuildMode.release);
      final state = PipelineState();
      await HuaweiStageAabStep().run(ctx, state);
      final expected = state[HuaweiStageAabStep.aabPath.id]! as String;

      // The upload tail fails before any credential/HTTP work (no
      // credential resolver injected — it must not be reached).
      final result = await AgcPublishStep(
        release: const HuaweiReleaseConfig(appId: '110012345'),
        credentialRef: const CredentialRef(
          target: 'huawei',
          kind: 'agconnect-credentials',
        ),
      ).run(ctx, state);

      expect(result.ok, isFalse);
      expect(result.error, contains('does not exist'));
      expect(result.error, contains(expected));
    });
  });
}
