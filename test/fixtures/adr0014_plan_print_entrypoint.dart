// ADR-0014 test fixture: a project entrypoint declaring a dry-run publish
// target plus a platform pipeline.
//
// Used by test/adr0014_plan_print_test.dart to exercise the ADR-0014
// dry-run law through `okaRun`'s target dispatch: a successful dry-run
// publish dispatch MUST print the plan; a platform build dispatch must not.
import 'package:oka_core/oka_core.dart';

/// Test-only publish target: dry-run by default, stages a fixture artifact
/// so the plan step can render (pure oka_core — no store packages needed).
class FixturePublishTarget extends PublishTarget {
  const FixturePublishTarget();

  static const artifact = Artifact<String>('fixture-artifact');

  @override
  bool get dryRun => true;

  @override
  String get name => 'publish-fixture';

  @override
  String get description => 'Test-only dry-run publish target';

  @override
  String get endpoint => 'Fixture Publisher API';

  @override
  String get track => 'internal';

  @override
  String get artifactId => artifact.id;

  @override
  Map<String, String> get metadata => const {'fixture': 'true'};

  @override
  List<BuildStep> publishSteps(final BuildContext ctx) => [_StageFixture()];

  @override
  BuildStep uploadStep(final BuildContext ctx) => throw UnsupportedError(
        'the fixture target is dry-run only — the upload tail never compiles',
      );
}

class _StageFixture extends BuildStep {
  @override
  String get name => 'stage-fixture';

  @override
  Set<Artifact<Object>> get provides => {FixturePublishTarget.artifact};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async {
    state[FixturePublishTarget.artifact.id] = '${ctx.buildDir}/fixture.aab';
    return StepResult.success();
  }
}

/// Test-only platform pipeline: succeeds without invoking any tool, the
/// same surface `oka build` dispatch uses (apk_path result data only).
class FixturePipeline implements PlatformPipeline {
  const FixturePipeline();

  @override
  String get platform => 'android';

  @override
  Map<String, dynamic> get configOverrides => const {};

  @override
  Future<StepResult> run(final BuildContext ctx) async => StepResult.success({
        'apk_path': '${ctx.buildDir}/app-debug.apk',
      });
}

/// Test-only no-op target: a non-publish target dispatch (no plan in
/// state — the plan header must not print).
class EchoTarget extends Target {
  const EchoTarget();

  @override
  String get name => 'echo';

  @override
  String get description => 'Test-only no-op target';

  @override
  List<BuildStep> compile(final BuildContext ctx) => [_EchoStep()];
}

class _EchoStep extends BuildStep {
  @override
  String get name => 'echo';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async =>
      StepResult.success();
}

Future<void> main(final List<String> args) => okaRun(
      args,
      oka: const Oka(pipelines: [FixturePipeline()], targets: [
        FixturePublishTarget(),
        EchoTarget(),
      ]),
    );
