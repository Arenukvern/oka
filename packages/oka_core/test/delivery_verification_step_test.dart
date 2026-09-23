import 'package:oka_core/oka_core.dart';
import 'package:test/test.dart';

/// Fake verifier with configurable gates (no platform tools involved).
class _FakeVerifier implements DeliveryVerifier {
  _FakeVerifier(this.gates);

  final Map<String, bool> gates;
  DeliveryVerificationReport? lastReport;

  @override
  Future<DeliveryVerificationReport> verify({
    required String artifact,
    required String outputDirectory,
    DeliveryVerificationOptions options = const DeliveryVerificationOptions(),
    bool verbose = false,
  }) async {
    lastReport = DeliveryVerificationReport(
      artifact: artifact,
      artifactSha256: 'a' * 64,
      artifactBytes: 7,
      abis: const ['arm64-v8a'],
      gates: gates,
    );
    return lastReport!;
  }
}

void main() {
  test('failing gates abort with gate names before upload', () async {
    const ctx = BuildContext(
      projectPath: '/p',
      buildDir: '/tmp/b',
      mode: BuildMode.release,
      config: OkaConfig.empty,
    );
    final state = PipelineState();
    state['aab-path'] = '/tmp/b/app.aab';
    final step = DeliveryVerificationStep(
      artifactId: 'aab-path',
      verifier: _FakeVerifier({
        'artifact_exists': true,
        'bundletool_validate': false,
      }),
    );
    final result = await step.run(ctx, state);
    expect(result.ok, isFalse);
    expect(result.error, contains('bundletool_validate'));
    expect(
      state[DeliveryVerificationStep.report.id],
      isA<DeliveryVerificationReport>(),
    );
  });

  test('passing gates succeed and record the report artifact', () async {
    const ctx = BuildContext(
      projectPath: '/p',
      buildDir: '/tmp/b',
      mode: BuildMode.release,
      config: OkaConfig.empty,
    );
    final state = PipelineState();
    state['aab-path'] = '/tmp/b/app.aab';
    final step = DeliveryVerificationStep(
      artifactId: 'aab-path',
      verifier: _FakeVerifier({'artifact_exists': true}),
    );
    final result = await step.run(ctx, state);
    expect(result.ok, isTrue);
  });

  test(
    'PublishTarget.compile inserts the gate in real mode with a verifier',
    () {
      final target = _FakePublishTarget(
        dryRun: false,
        verifier: _FakeVerifier({'artifact_exists': true}),
      );
      const ctx = BuildContext(
        projectPath: '/p',
        buildDir: '/tmp/b',
        mode: BuildMode.release,
        config: OkaConfig.empty,
      );
      final steps = target.compile(ctx);
      expect(steps.map((final s) => s.name), contains('verify-delivery'));
      // Gate runs after staging, before the upload tail.
      final names = steps.map((final s) => s.name).toList();
      expect(
        names.indexOf('verify-delivery'),
        lessThan(names.indexOf('upload')),
      );
    },
  );

  test(
    'dry-run plans never run the gate; real mode refusals throw at compile',
    () {
      const dry = _FakePublishTarget(dryRun: true);
      expect(
        dry
            .compile(
              const BuildContext(
                projectPath: '/p',
                buildDir: '/tmp/b',
                mode: BuildMode.release,
                config: OkaConfig.empty,
              ),
            )
            .map((final s) => s.name),
        isNot(contains('verify-delivery')),
      );
      const refusing = _RefusingTarget();
      expect(
        () => refusing.compile(
          const BuildContext(
            projectPath: '/p',
            buildDir: '/tmp/b',
            mode: BuildMode.release,
            config: OkaConfig.empty,
          ),
        ),
        throwsArgumentError,
      );
    },
  );
}

class _FakePublishTarget extends PublishTarget {
  const _FakePublishTarget({required this.dryRun, this.verifier});

  @override
  final bool dryRun;
  @override
  final DeliveryVerifier? verifier;

  @override
  String get name => 'fake-publish';
  @override
  String get description => 'fake publish target';
  @override
  String get endpoint => 'fake';
  @override
  String get track => 'test';
  @override
  String get artifactId => 'aab-path';

  @override
  List<BuildStep> publishSteps(final BuildContext ctx) => [StageAabStep()];

  @override
  BuildStep uploadStep(final BuildContext ctx) => _NoopUploadStep();
}

class _RefusingTarget extends _FakePublishTarget {
  const _RefusingTarget() : super(dryRun: false);

  @override
  List<String> validateRealMode() => const ['cannot run for real'];
}

class _NoopUploadStep extends BuildStep {
  @override
  String get name => 'upload';

  @override
  Set<Artifact<Object>> get requires => {const Artifact<String>('aab-path')};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) =>
      Future.value(StepResult.success());
}
