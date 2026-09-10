// ADR-0018 L1 — the best-effort TeardownRunner: never masks the forward
// result, never throws, every step bounded by its timeout.
import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

class OkStep extends BuildStep {
  @override
  String get name => 'ok-step';

  @override
  Future<StepResult> run(
    final BuildContext ctx,
    final PipelineState state,
  ) async =>
      StepResult.success();
}

class FailingStep extends BuildStep {
  @override
  String get name => 'failing-step';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async =>
      StepResult.failure('device not attached');
}

class ThrowingStep extends BuildStep {
  @override
  String get name => 'throwing-step';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async =>
      throw StateError('broken step');
}

class SlowStep extends BuildStep {
  @override
  String get name => 'slow-step';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) =>
      Future<StepResult>.delayed(const Duration(seconds: 5), StepResult.success);
}

class ReadingStep extends BuildStep {
  ReadingStep(this.artifact);

  final Artifact<String> artifact;

  @override
  String get name => 'reading-step';

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) async =>
      (state[artifact.id] as String?) == null
          ? StepResult.failure('missing artifact')
          : StepResult.success();
}

BuildContext _ctx() => const BuildContext(
      projectPath: '/tmp/x',
      buildDir: '/tmp/x/.oka_cache',
      mode: BuildMode.debug,
      config: OkaConfig.empty,
      cacheDir: '/tmp/x/.oka_cache',
    );

void main() {
  test('all clean → ok, no failures', () async {
    final o = await runTeardownSteps([OkStep(), OkStep()], ctx: _ctx());
    expect(o.ok, isTrue);
    expect(o.failures, isEmpty);
  });

  test('a failing step is collected, never throws; later steps still run',
      () async {
    final o = await runTeardownSteps([
      FailingStep(),
      OkStep(),
    ], ctx: _ctx());
    expect(o.ok, isFalse);
    expect(o.failures.single.step, 'failing-step');
    expect(o.failures.single.error, contains('device not attached'));
  });

  test('a throwing step is a collected failure, not a crash', () async {
    final o = await runTeardownSteps([ThrowingStep()], ctx: _ctx());
    expect(o.ok, isFalse);
    expect(o.failures.single.error, contains('broken step'));
  });

  test('per-step timeout bounds a hung stop', () async {
    final sw = Stopwatch()..start();
    final o = await runTeardownSteps(
      [SlowStep()],
      ctx: _ctx(),
      perStepTimeout: const Duration(milliseconds: 50),
    );
    sw.stop();
    expect(o.ok, isFalse);
    expect(o.failures.single.error, contains('timed out'));
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test("steps consume the forward run's state artifacts", () async {
    final state = PipelineState()
      ..['apk-path'] = '/tmp/x/app.apk';
    final ok = await runTeardownSteps(
      [ReadingStep(const Artifact<String>('apk-path'))],
      ctx: _ctx(),
      state: state,
    );
    expect(ok.ok, isTrue);
    final missing = await runTeardownSteps(
      [ReadingStep(const Artifact<String>('vm_service_uri'))],
      ctx: _ctx(),
      state: state,
    );
    expect(missing.ok, isFalse);
  });
}
