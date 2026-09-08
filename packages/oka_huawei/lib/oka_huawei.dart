/// Huawei AppGallery Connect distribution target for oka (ADR-0014 P2).
///
/// This package ships the `huawei` store target per the ADR-0013 two-axis
/// model: distribution targets are **not** platforms — a store target is a
/// build-variant composition (here: the GMS-excluding
/// [HuaweiBuildVariant]) plus a publish tail ([HuaweiPublishTarget]), both
/// built on `oka_core` + `oka_android` contracts.
///
/// ## The publish target
///
/// ```dart
/// import 'package:oka_huawei/oka_huawei.dart';
///
/// const target = HuaweiPublishTarget(
///   dryRun: true, // default: plan, never upload
///   release: HuaweiReleaseConfig(
///     appId: '110012345',
///     track: HuaweiReleaseConfig.defaultTrack,
///   ),
/// );
/// ```
///
/// With `dryRun: true` the compiled chain produces a `PublishPlan`
/// describing exactly what a real run would do (endpoint, track, artifact,
/// metadata) and issues **no HTTP**. With `dryRun: false` the upload tail
/// runs the AppGallery Connect REST flow — token fetch → upload-url →
/// artifact upload → submit — with credentials resolved **by path** via
/// the `huawei/agconnect-credentials` `CredentialRef` policy.
///
/// ## GMS exclusion
///
/// [HuaweiBuildVariant] filters GMS-provided Maven coordinates out of
/// `extraDeps` (classification via the `oka_android` seam) and gives
/// GMS-provided artifacts typed ids (`gms-dep:<coordinate>`): a step
/// requiring one fails the standard artifact validator at composition time
/// — before any tool runs.
///
/// See also:
///
/// * `oka_core` `PublishTarget` — the contract and the conformance laws.
/// * ADR-0013 (two-axis model), ADR-0014 (targets + secrets model).
///
/// A full, compiling composition lives in
/// `example/oka_pipeline_example.dart` (the quickstart in the package
/// README is the same code).
library;

export 'src/huawei_publish_target.dart';
