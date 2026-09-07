/// How to make your own oka publish target conform (ADR-0014), as a real,
/// compiling file.
///
/// The contract: extend [PublishTarget] (oka_core), implement the typed
/// members, and assert the three publishing laws with this package's
/// suite — from your target package's tests:
///
/// ```dart
/// test('my-target conforms (ADR-0014)', () async {
///   await expectPublishConformance(
///     const MyPublishTarget(),
///     ctx,
///     sourcePaths: [p.absolute('lib/src')],
///   );
/// });
/// ```
///
/// This example runs the same assertions from `main()` so it reads as a
/// complete, offline program: no credentials, no network (a
/// [FakeHttpTransport] canary proves zero HTTP), no artifacts on disk.
///
/// The three laws (ADR-0014):
///
/// 1. **Dry-run without credentials succeeds** and produces a plan
///    describing exactly what a real run would do.
/// 2. **No stdin, ever** (asserted over the package's Dart sources).
/// 3. **No secret values in state, logs, or events.**
library;

import 'package:oka_conformance/oka_conformance.dart';

/// A minimal example target: stages a demo artifact and (in real mode)
/// would upload it to a fictional endpoint. With [dryRun] true (the
/// default), the compiled chain swaps the upload step for oka_core's
/// plan step — exactly how `oka_play`/`oka_huawei` targets work.
class DemoPublishTarget extends PublishTarget {
  const DemoPublishTarget();

  @override
  bool get dryRun => true; // the law-1 default; real mode is explicit

  @override
  String get name => 'publish-demo';

  @override
  String get description => 'Upload the demo artifact (dry run by default)';

  @override
  String get endpoint => 'Demo Publish API (example/v1)';

  @override
  String get track => 'beta';

  @override
  String get artifactId => 'demo-path';

  @override
  Map<String, String> get metadata => const {'demoAppId': '42'};

  @override
  List<CredentialRef> get credentialRefs => const [
        CredentialRef(target: 'demo', kind: 'api-client-credentials'),
      ];

  @override
  List<BuildStep> publishSteps(final BuildContext ctx) => [
        _StageDemoStep(),
      ];

  @override
  BuildStep uploadStep(final BuildContext ctx) =>
      throw UnimplementedError('real upload tail is out of scope for the '
          'example; dry-run compiles a plan step instead of this step');
}

/// Stages the publish artifact the upload tail (or the plan step) consumes.
class _StageDemoStep extends BuildStep {
  static const demoArtifact = Artifact<String>('demo-path');

  @override
  String get name => 'stage-demo';

  @override
  Set<Artifact<Object>> get provides => {demoArtifact};

  @override
  Future<StepResult> run(final BuildContext ctx, final PipelineState state) {
    state[demoArtifact.id] = '${ctx.buildDir}/demo/demo-release.aab';
    return Future<StepResult>.value(StepResult.success());
  }
}

Future<void> main() async {
  const ctx = BuildContext.empty;
  const target = DemoPublishTarget();

  // ── The three laws, in one call (throwing assertions) ────────────────
  // In a real package this lives in test/ and also scans lib/src for
  // stdin usage (law 2):
  //
  //   await expectPublishConformance(target, ctx,
  //       sourcePaths: [p.absolute('lib/src')]);
  final violations = await auditPublishConformance(target, ctx);
  if (violations.isNotEmpty) {
    throw StateError('conformance violations:\n${violations.join('\n')}');
  }

  // ── Law 1 in detail: the dry-run plan shape, offline ─────────────────
  final state = PipelineState();
  final result =
      await Pipeline(target.compile(ctx)).run(ctx, initialState: state);
  if (!result.ok) throw StateError('dry-run failed: ${result.error}');
  final plan = state[PublishPlanStep.plan.id]! as PublishPlan;

  // Zero HTTP — the canary throws if anything dared to send a request.
  FakeHttpTransport().assertNoRequests();

  expectPlanShape(
    plan,
    target: 'publish-demo',
    endpoint: 'Demo Publish API (example/v1)',
    track: 'beta',
    artifactId: 'demo-path',
    dryRun: true,
    metadata: const {'demoAppId': '42'},
    credentials: const [
      CredentialRef(target: 'demo', kind: 'api-client-credentials'),
    ],
  );
  expectPlanDescribes(plan, [
    'target: publish-demo (dry run — nothing was uploaded)',
    'credential: CredentialRef(demo/api-client-credentials → [redacted])',
  ]);

  // ── Law 3 in detail: the state dump carries no secret material ───────
  expectStateRedacted(state, refs: target.credentialRefs);
}
