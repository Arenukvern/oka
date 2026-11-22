/// The Huawei AppGallery STORE package for oka (ADR-0055, ADR-0056).
///
/// A store package is the store's identity plus its publish channel —
/// never a platform. A Huawei DEVICE is a platform composition (the
/// GMS-free build posture lives in `oka_huawei`); a RuStore build can ship
/// to the very same device. This package is only about AppGallery the
/// store: its key, and the AppGallery Connect publish channel.
///
/// ## The store key
///
/// ```dart
/// import 'package:oka_app_gallery/oka_app_gallery.dart';
///
/// const appgallery = storeKeyAppGallery; // StoreKey('appgallery')
/// ```
///
/// The key is a convenience constant (ADR-0056: store packages carry their
/// own key; there is no central registry). A build-side composition may
/// import it freely; a runtime kernel should compose its own
/// `StoreKey('appgallery')` instead of pulling channel machinery into the
/// binary just to name a store.
///
/// ## The publish target
///
/// ```dart
/// import 'package:oka_app_gallery/oka_app_gallery.dart';
///
/// const target = AppGalleryPublishTarget(
///   dryRun: true, // default: plan, never upload
///   release: AppGalleryReleaseConfig(
///     appId: '110012345',
///     track: AppGalleryReleaseConfig.defaultTrack,
///   ),
/// );
/// ```
///
/// With `dryRun: true` the compiled chain produces a `PublishPlan`
/// describing exactly what a real run would do (endpoint, track, artifact,
/// metadata) and issues **no HTTP**. With `dryRun: false` the upload tail
/// runs the AppGallery Connect REST flow — token fetch → upload-url →
/// artifact upload → submit — with credentials resolved **by path** via
/// the `appgallery/agconnect-credentials` `CredentialRef` policy.
///
/// The target is a **channel only** (ADR-0055): it consumes the artifact a
/// delivery's pipeline produced — the GMS-free posture is the DELIVERY's
/// job (`hms-free` overlay excludes the Google SDK groups; this channel
/// prohibits the `gms` overlay at composition time). The opt-in
/// [AppGalleryPublishTarget] `verifyArtifact` filesystem gate derives its
/// exclusion set from the delivery context's overlays, so one source of
/// truth carries the GMS-free boundary from composition through
/// verification.
///
/// See also:
///
/// * `oka_core` `PublishTarget` — the contract and the conformance laws.
/// * `oka_huawei` — the Huawei-device PLATFORM package (GMS-free build
///   composition); ADR-0056 for the store/platform line.
/// * ADR-0014 (targets + secrets model).
library;

export 'src/agc_api.dart';
export 'src/agc_credentials.dart';
export 'src/agc_publish_step.dart';
export 'src/appgallery_distribution_policy.dart';
export 'src/appgallery_publish_target.dart';
export 'src/appgallery_release_config.dart';
export 'src/appgallery_store_key.dart';
