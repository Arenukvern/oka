/// Shared publish-target conformance suite for oka (ADR-0014).
///
/// The reusable test harness every oka target package imports from its
/// tests — the `universal_storage_conformance` pattern applied to oka
/// publishing:
///
/// ```dart
/// import 'package:oka_conformance/oka_conformance.dart';
///
/// test('publish-play conforms (ADR-0014)', () async {
///   await expectPublishConformance(
///     const PlayPublishTarget(),
///     ctx,
///     sourcePaths: [p.absolute('lib/src')],
///   );
/// });
/// ```
///
/// The three laws (ADR-0014):
///
/// 1. **Dry-run without credentials succeeds** and produces a
///    [PublishPlan] describing exactly what a real run would do — assert
///    its shape with [expectPlanShape] / [expectPlanDescribes].
/// 2. **No stdin, ever** — enforced by [expectPublishConformance] over
///    `sourcePaths`.
/// 3. **No secret values in state, logs, or events** — assert over any
///    dumped text with [expectNoSecretMaterial] / [expectStateRedacted],
///    and prove zero HTTP with [FakeHttpTransport.assertNoRequests].
///
/// [FakeHttpTransport] is the offline transport for the real-run tests:
/// fully scripted, recording, and throwing on unexpected requests — tests
/// stay offline by construction.
library;

export 'package:oka_core/oka_core.dart'
    show
        Artifact,
        BuildContext,
        BuildMode,
        BuildStep,
        CredentialRef,
        CredentialResolution,
        CredentialResolutionException,
        CredentialResolver,
        CredentialSource,
        CredentialSourceKind,
        OkaConfig,
        Pipeline,
        PipelineState,
        PublishConformanceException,
        PublishPlan,
        PublishPlanStep,
        PublishTarget,
        StepResult,
        auditPublishConformance,
        describeTarget,
        expectPublishConformance,
        isSecretishKey,
        secretishKeyPatterns,
        validateTargetName;
export 'src/fake_http_transport.dart';
export 'src/plan_shape.dart';
export 'src/redaction.dart';
